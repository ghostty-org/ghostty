const std = @import("std");
const build_options = @import("terminal_options");
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
const kitty_gfx = @import("kitty.zig").graphics;

const log = std.log.scoped(.render_state);

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
/// ## Overscan
///
/// By default the render state captures exactly the rows of the viewport.
/// A renderer that draws the grid at a fractional row offset, such as for
/// smooth scrolling, also needs the rows just outside the viewport so that
/// partially visible rows at the top and bottom edges can be drawn. Set
/// `overscan_request` to ask for extra rows above and below the viewport:
///
///     var state: RenderState = .empty;
///     defer state.deinit(alloc);
///     state.overscan_request = .{ .above = 1, .below = 1 };
///     try state.update(alloc, &terminal);
///
/// With overscan, `row_data` holds more than `rows` entries, laid out
/// like this for a request of one row above and one below:
///
///     index 0            overscan above   (viewport y = -1)
///     index 1            viewport row 0   <- viewportStart()
///     ...
///     index rows         viewport row rows - 1
///     index rows + 1     overscan below   (viewport y = rows)
///
/// The viewport always begins at `viewportStart()`, so viewport rows never
/// move within `row_data` from one update to the next. The overscan rows
/// are only captured if they exist. There is nothing above the first row
/// of scrollback, and nothing below the viewport while it follows the
/// active area (the usual case when not scrolled). Missing rows leave
/// their entries unused, and `overscan` reports how many rows were
/// actually captured. Always read rows through `rowDataRange()`:
///
///     const range = state.rowDataRange();
///     const rows = state.row_data.slice();
///     for (range.start..range.end) |i| {
///         const y = state.viewportY(i); // negative above the viewport
///         const cells = rows.items(.cells)[i];
///         // draw `cells` at row `y` shifted by the scroll offset
///     }
///
/// Overscan rows carry the same data as viewport rows (cells, styles,
/// dirty flags, selection, and highlights). The cursor is only reported
/// in `cursor.viewport` when it is inside the viewport itself. `string`
/// and `linkCells` only look at the viewport.
///
/// With no overscan requested (the default), `row_data` holds exactly
/// the viewport and indices are viewport y values, as before.
///
/// ## Images
///
/// The render state also gives the images to draw, as a list of image
/// placements (`ImagePlacement`). Each one is a rectangle of one image,
/// with its position, size, source rectangle and draw order. These mean
/// the same thing for every image protocol, so a renderer can draw them
/// all the same way. Only reading the pixels depends on the protocol:
///
///     var it = state.imagePlacementIterator();
///     while (it.next()) |p| {
///         // `kittyTexture` and `queue` stand in for your renderer.
///         // Find or upload a texture keyed by the protocol, image ID
///         // and image generation. Only read pixels on a miss.
///         const texture = switch (p.protocol) {
///             .kitty => kittyTexture(p.image_id, p.image_generation),
///         };
///
///         // Draw p.source_* of the texture at cell (p.x, p.y), offset
///         // by (p.offset_x, p.offset_y) pixels, at a size of p.width by
///         // p.height pixels, sorted by p.layer and then p.z.
///         queue(texture, p);
///     }
///
/// ### Knowing When Images Changed
///
/// Most frames don't change any image. A program prints text or moves the
/// cursor, and every image stays where it was. You don't need to rebuild
/// your image draw list on those frames. After each update, call
/// `imagePlacementsGeneration` and compare the result with the value from
/// the last time you read the list. If the two match, the list is the
/// same as before, and you can keep drawing what you built last time:
///
///     // Kept by your renderer between frames. Null until the list has
///     // been read once, so that the first frame always reads it.
///     var placements_generation: ?u64 = null;
///
///     // Each frame:
///     try state.update(alloc, &terminal);
///     const generation = state.imagePlacementsGeneration();
///     if (placements_generation != generation) {
///         placements_generation = generation;
///         rebuildImageDrawList(state.imagePlacementIterator());
///     }
///     drawImageDrawList();
///
/// The value changes when an update adds or removes an image, moves one,
/// changes which part of one is shown, or changes the pixels of one. It
/// stays the same when only text changes, as long as the changed rows had
/// no Kitty placeholder cells before or after the change. (See "Kitty
/// Graphics Placeholders" below for what those are.)
///
/// A new value means "read the list again". It doesn't promise that
/// anything on screen moved. The value can change even when every image
/// ends up exactly where it was, for example:
///
///   - When a program rewrites a row that has placeholder cells.
///   - When a program changes any image or placement while images shown
///     with placeholder cells are on screen.
///
/// Only compare the value for equality. It wraps around, so a larger
/// value doesn't mean a newer one. It is always 0 when Kitty graphics are
/// disabled.
///
/// Don't confuse this value with `ImagePlacement.image_generation`. That
/// one belongs to a single image and tells you when to upload its pixels
/// again. This one belongs to the whole list and tells you when to read
/// the list again.
///
/// ### Which Images Are Included
///
/// The list holds every Kitty graphics image on screen:
///
///   - Images shown with placeholder cells. See "Kitty Graphics
///     Placeholders" below.
///   - Images placed at a cell on the screen. These scroll with the
///     text around them, like a line of output. See "Kitty Graphics
///     Fixed Placements" below.
///   - Images placed relative to another image. See "Kitty Graphics
///     Relative Placements" below.
///
/// You don't need to read the terminal's Kitty image storage to find
/// what to draw. Don't draw images from the storage as well, or they are
/// drawn twice.
///
/// ### Images Partly Outside the Captured Rows
///
/// An image is in the list when any part of it is in the captured rows
/// (the viewport plus any overscan rows). Images shown with placeholder
/// cells are split into one placement per row of cells, so each of those
/// placements is always inside the captured rows.
///
/// Every other placement is reported at its full size, even when only
/// part of it can be seen. Its `x` can be negative, and its `y` can be
/// above the first overscan row. It can also extend past the right or
/// bottom edge. Clip it to the area you draw. Most graphics APIs can do
/// this for you with a scissor or clip rectangle. For example, with no
/// overscan:
///
///     // A fixed image 4 rows tall whose top row scrolled 2 rows above
///     // the viewport has y = -2 and rows = 4. Its pixel position is
///     // found the usual way, and `top` is negative.
///     const left = p.x * cell_width + p.offset_x;
///     const top = p.y * cell_height + p.offset_y;
///
///     // Clip to the viewport and draw the whole image. Rows -2 and -1
///     // are cut off, and rows 0 and 1 show at the top of the viewport.
///     setClip(0, 0, viewport_width, viewport_height);
///     drawImage(texture, p, left, top, p.width, p.height);
///
/// ### Kitty Graphics Fixed Placements
///
/// A program can place a Kitty image at a cell on the screen. The image
/// is attached to that cell, so it moves when the text moves: when new
/// output scrolls the screen, when a program scrolls part of the screen,
/// and when the viewport scrolls through the scrollback.
///
/// The render state finds the position of these images during each
/// update. Most updates only need a few comparisons for this. When the
/// images or the cell size change, the render state reads the image
/// storage again. When only their positions can have changed, such as
/// on a scroll, it moves the images it already knows about without
/// reading the storage.
///
/// ### Kitty Graphics Placeholders
///
/// The Kitty graphics protocol lets a program place an image with text.
/// The program creates a virtual placement, which has no position of its
/// own, and prints placeholder characters (U+10EEEE) where the image
/// should appear. Each placeholder cell says which image it shows and
/// which piece of the image belongs in that cell. The image then moves
/// with the text.
///
/// Because the cells decide where these images go, the render state
/// works out where to draw them during each update:
///
///   1. When a row is rebuilt, its placeholder cells are grouped into
///      runs of neighboring cells that show the same image. These are
///      stored in `Row.placeholders`.
///   2. `beginUpdate` then looks up each new run's image and placement
///      and calculates the part of the image it shows, and where. Runs
///      on rows that didn't change keep their results, unless the
///      images or the cell size changed.
///   3. Relative placements attached to a virtual placement are
///      positioned from that placement's runs.
///
/// ### Kitty Graphics Relative Placements
///
/// A program can also place a Kitty image relative to another placement,
/// its parent. The image is drawn a number of cells to the right of and
/// below its parent. Negative numbers move it left or up. The parent can
/// be relative to another placement too, so placements can form a chain.
///
/// The render state follows the chain to the placement at its start and
/// positions the image from there:
///
///   - If the chain starts at an image placed at a cell, the image is
///     drawn from that cell, and moves whenever that cell moves.
///   - If the chain starts at a virtual placement, the image is drawn
///     from the top-left corner of that placement's placeholder cells.
///     If none of those cells are in the captured rows, the image is not
///     in the list.
///
/// For example, an image placed 3 columns right of and 2 rows below a
/// parent at column 2, row 1 is drawn at column 5, row 3. Like other
/// placements, it is in the list when any part of it is in the captured
/// rows, even if its parent isn't.
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
    /// is also the viewport size. It does not include overscan rows.
    rows: size.CellCountInt,
    cols: size.CellCountInt,

    /// The color state for the terminal.
    colors: Colors,

    /// Cursor state within the viewport.
    cursor: Cursor,

    /// The captured rows, from top to bottom.
    ///
    /// Without overscan this has exactly `rows` entries and the index is
    /// the viewport y. With overscan it has room for the requested rows
    /// above and below the viewport, and the viewport starts at
    /// `viewportStart()`. Only the entries in `rowDataRange()` hold data
    /// from the last update. See "Overscan" in the `RenderState` docs.
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

    /// The number of rows to capture above and below the viewport. This is
    /// for renderers that draw partially visible rows, such as during
    /// smooth scrolling. The default of zero captures only the viewport.
    /// See "Overscan" in the `RenderState` docs.
    ///
    /// Only change this immediately before an update, because
    /// `viewportStart()` reads it and `row_data` is laid out for it by the
    /// update. Changing it causes the next update to be a full redraw.
    overscan_request: Overscan = .{},

    /// The number of rows above and below the viewport that the last
    /// update actually captured. This is never more than
    /// `overscan_request`, and is less when those rows don't exist:
    ///
    ///   - `above` is less near the top of the scrollback.
    ///   - `below` is less when the viewport is close to the bottom of
    ///     the screen, and is zero when the viewport follows the active
    ///     area.
    ///
    /// This is set by the update and should not be modified.
    overscan: Overscan = .{},

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

    /// Internal state for Kitty graphics placeholders. Read the results
    /// with `imagePlacementIterator` instead.
    kitty: Kitty.Data = .{},

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

    /// A number of rows above and below the viewport. Used both to request
    /// overscan (`overscan_request`) and to report what was captured
    /// (`overscan`).
    pub const Overscan = struct {
        /// Rows above the top of the viewport.
        above: size.CellCountInt = 0,

        /// Rows below the bottom of the viewport.
        below: size.CellCountInt = 0,

        pub fn eql(a: Overscan, b: Overscan) bool {
            return a.above == b.above and a.below == b.below;
        }
    };

    /// A captured row. This is either a viewport row or an overscan row,
    /// depending on its index in `row_data`.
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

        /// The runs of Kitty graphics placeholder cells in this row, from
        /// left to right. Most callers want `imagePlacementIterator`,
        /// which reads these for every row. This is always empty when
        /// Kitty graphics are disabled.
        ///
        /// This uses the row arena, like highlights.
        placeholders: std.ArrayList(Placeholder),

        /// The style runs applied to this row's per-cell style data
        /// by the last `endUpdate` that touched it. This is what lets
        /// `endUpdate` skip the (comparatively large) per-cell style
        /// fill when a rebuilt row produced identical runs, which is
        /// the common case: text changes far more often than styling.
        ///
        /// The invariant is that this always describes the current
        /// contents of the cell style data for the covered ranges. It
        /// is cleared whenever the cell storage is reallocated.
        ///
        /// This uses the general allocator (NOT the row arena)
        /// because it must survive row rebuilds. `endUpdate` cannot
        /// allocate, so `beginUpdate` reserves the capacity.
        applied_styles: std.ArrayList(StyleRun),

        /// Identifies a row of terminal content across updates, independent
        /// of where the row is in `row_data`. Get it with `id`.
        ///
        /// When the viewport scrolls, rows move to different `row_data`
        /// indices but keep their ids. This lets a renderer keep per-row
        /// work (such as shaped text or cached geometry) and look it up by
        /// id after each update rather than rebuilding everything:
        ///
        ///     const range = state.rowDataRange();
        ///     for (range.start..range.end) |i| {
        ///         const row = state.row_data.get(i);
        ///         if (!row.dirty) {
        ///             if (cache.get(row.id())) |cached| {
        ///                 // reuse `cached` at the new position
        ///                 continue;
        ///             }
        ///         }
        ///         // rebuild this row and cache it under row.id()
        ///     }
        ///
        /// The guarantee is: if a row has the same id as a row from the
        /// previous update of the same render state and is not marked dirty,
        /// its contents are unchanged. An id that no longer appears means
        /// the row scrolled out of the captured rows, was removed from
        /// scrollback, or was rearranged in place by the terminal (for
        /// example, scrolling within a scroll region). Ids are never reused,
        /// so a stale id never matches a different row.
        pub const Id = struct {
            /// The generation of the page holding the row
            /// (`PageList.List.Node.serial`).
            serial: u64,

            /// The row index within its page.
            y: size.CellCountInt,

            pub fn eql(a: Id, b: Id) bool {
                return a.serial == b.serial and a.y == b.y;
            }
        };

        /// Returns the identity of this row. See `Id`.
        ///
        /// This only reads values copied during the update, so it is safe
        /// to call without access to the terminal.
        pub fn id(self: *const Row) Id {
            return .{ .serial = self.serial, .y = self.pin.y };
        }
    };

    pub const Highlight = struct {
        /// A special tag that can be used by the caller to differentiate
        /// different highlight types. The value is opaque to the RenderState.
        tag: u8,

        /// The x ranges of highlights within this row.
        range: [2]size.CellCountInt,
    };

    /// A run of neighboring Kitty graphics placeholder cells in one row.
    /// See `Row.placeholders`.
    pub const Placeholder = Kitty.Placeholder;

    /// The image protocols that a render state can find image placements
    /// for. See `ImagePlacement.protocol`.
    pub const ImageProtocol = lib.Enum(lib.target, &.{
        // The Kitty graphics protocol.
        "kitty",
    });

    /// Where an image is drawn relative to the text of the terminal.
    ///
    /// Draw in this order: images below backgrounds, then cell
    /// backgrounds, then images below text, then text, then images above
    /// text. Within a layer, draw images in order of their z-index,
    /// lowest first.
    pub const ImageLayer = lib.Enum(lib.target, &.{
        // Below the cell background colors.
        "below_background",

        // Above the cell background colors and below the text.
        "below_text",

        // Above the text.
        "above_text",
    });

    /// Returns the layer that an image with the given Kitty graphics
    /// z-index is drawn in.
    ///
    /// Kitty graphics uses the z-index for two things: which layer an
    /// image is drawn in, and the order of images within that layer. The
    /// layer follows these ranges, which match Kitty:
    ///
    ///   - Below `minInt(i32) / 2` (-1,073,741,824): `below_background`.
    ///   - From there up to -1: `below_text`.
    ///   - Zero and above: `above_text`.
    ///
    /// Every `ImagePlacement` already has its `layer` set, so you only
    /// need this when you get a z-index from somewhere else, such as the
    /// terminal's Kitty image storage.
    ///
    /// Example:
    ///
    ///     imageLayerFromZ(-1); // .below_text
    ///     imageLayerFromZ(0); // .above_text
    ///     imageLayerFromZ(std.math.minInt(i32)); // .below_background
    pub fn imageLayerFromZ(z: i32) ImageLayer {
        return if (z < std.math.minInt(i32) / 2)
            .below_background
        else if (z < 0)
            .below_text
        else
            .above_text;
    }

    /// One rectangle of an image to draw. See `imagePlacementIterator`.
    ///
    /// To draw it, take the `source_*` rectangle of the image and draw
    /// it `width` by `height` pixels in size, at this position:
    ///
    ///     px_x = x * cell_width + offset_x
    ///     px_y = y * cell_height + offset_y
    ///
    /// where (px_x, px_y) is relative to the top-left of the viewport.
    /// Get the image's pixels from the storage of its `protocol`, using
    /// `image_id`.
    pub const ImagePlacement = struct {
        /// The protocol the image came from, and the information that
        /// only applies to that protocol.
        protocol: Protocol,

        /// The ID of the image to draw. IDs are only unique within one
        /// protocol, so always look the image up in the storage of
        /// `protocol`.
        image_id: u32,

        /// The generation of the image's contents when the placement was
        /// found. It changes whenever the image's pixels change, so it
        /// works as a cache key for textures: if it matches the texture
        /// you already have for this protocol and image ID, you don't
        /// need to read the pixels again.
        image_generation: u64,

        /// The layer to draw the image in, and the z-index that orders
        /// images within the layer. Lower z-indexes are drawn first.
        layer: ImageLayer,
        z: i32,

        /// The top-left cell, where (0, 0) is the top-left cell of the
        /// viewport. `y` is negative for overscan rows above the
        /// viewport, like `viewportY`.
        ///
        /// A placement that is only partly in the captured rows can start
        /// left of the viewport or outside the captured rows, so `x` can
        /// be negative and `y` can be above the first overscan row. See
        /// "Images Partly Outside the Captured Rows" in the `RenderState`
        /// docs.
        x: i32,
        y: i32,

        /// The number of columns and rows of cells covered, starting at
        /// `x` and `y`.
        cols: u32,
        rows: u32,

        /// Where the image starts within the top-left cell, in pixels.
        /// For a virtual run, an image that doesn't fill its cells is
        /// centered, so these can be larger than one cell. For fixed and
        /// relative placements, these are the offsets the program asked
        /// for, limited to less than one cell.
        offset_x: u32,
        offset_y: u32,

        /// The size to draw the image at, in pixels.
        width: u32,
        height: u32,

        /// The part of the image to draw, in image pixels.
        source_x: u32,
        source_y: u32,
        source_width: u32,
        source_height: u32,

        pub const Protocol = union(ImageProtocol) {
            kitty: KittyPlacement,
        };
    };

    /// Information that only applies to Kitty graphics placements. See
    /// `ImagePlacement.protocol`.
    pub const KittyPlacement = Kitty.Placement;

    /// Iterates over the image placements found by the last update. Get
    /// one with `imagePlacementIterator`.
    ///
    /// The order is not the order to draw in. Sort by layer and then
    /// z-index before drawing. Only placements with something to draw
    /// are returned.
    ///
    /// The iterator returns the placeholder runs of each row first, then
    /// the placements in `placed`. Build one with
    /// `imagePlacementIterator` rather than setting the fields yourself.
    pub const ImagePlacementIterator = struct {
        /// The placeholder runs of each captured row, top to bottom.
        rows: []const std.ArrayList(Placeholder),

        /// The viewport y position of the first entry in `rows`. It is
        /// negative when there are overscan rows above the viewport.
        viewport_y_base: isize,

        /// Placements that already have their final position, returned
        /// after all of the placeholder runs. These are the placements
        /// that are not placeholder runs: fixed and relative placements.
        placed: []const ImagePlacement,

        /// The current index into `rows`.
        y: usize = 0,

        /// The current index into the runs of `rows[y]`, or into
        /// `placed` once every row is done.
        i: usize = 0,

        pub fn next(self: *ImagePlacementIterator) ?ImagePlacement {
            while (self.y < self.rows.len) {
                const runs = self.rows[self.y].items;
                while (self.i < runs.len) {
                    const run = &runs[self.i];
                    self.i += 1;
                    if (run.state != .visible) continue;
                    const g = run.geometry;
                    return .{
                        .protocol = .{ .kitty = .{
                            .kind = .virtual,
                            .placement_id = run.placement_id,
                        } },
                        .image_id = run.image_id,
                        .image_generation = g.image_generation,
                        .layer = .below_text,
                        .z = -1,
                        .x = run.x,
                        .y = @intCast(self.viewport_y_base + @as(isize, @intCast(self.y))),
                        .cols = run.width,
                        .rows = 1,
                        .offset_x = g.offset_x,
                        .offset_y = g.offset_y,
                        .width = g.width,
                        .height = g.height,
                        .source_x = g.source_x,
                        .source_y = g.source_y,
                        .source_width = g.source_width,
                        .source_height = g.source_height,
                    };
                }
                self.y += 1;
                self.i = 0;
            }

            const idx = self.i;
            if (idx >= self.placed.len) return null;
            self.i += 1;
            return self.placed[idx];
        }
    };

    /// Returns an iterator over the image placements that the last update
    /// found. This covers every captured row, including overscan rows.
    ///
    /// See "Which Images Are Included" in the `RenderState` docs for the
    /// kinds of images in the list. Some placements are only partly in
    /// the captured rows and must be clipped when drawn. See "Images
    /// Partly Outside the Captured Rows" in the `RenderState` docs.
    ///
    /// This only reads memory owned by the render state, so it doesn't
    /// need access to the terminal. The next update invalidates the
    /// iterator.
    pub fn imagePlacementIterator(self: *const RenderState) ImagePlacementIterator {
        const range = self.rowDataRange();
        return .{
            .rows = self.row_data.items(.placeholders)[range.start..range.end],
            .viewport_y_base = self.viewportY(range.start),
            .placed = self.kitty.placed.items,
        };
    }

    /// Returns a value that changes whenever an update changes the
    /// placements that `imagePlacementIterator` returns. If it matches the
    /// value from the last time you read the iterator, the placements are
    /// the same and you don't need to read them again. See "Knowing When
    /// Images Changed" in the `RenderState` docs for an example and for
    /// exactly when the value changes.
    ///
    /// The value belongs to the whole list. To know when the pixels of a
    /// single image changed, use `ImagePlacement.image_generation`.
    ///
    /// Only compare the value for equality. It is always 0 when Kitty
    /// graphics are disabled.
    pub fn imagePlacementsGeneration(self: *const RenderState) u64 {
        if (comptime !build_options.kitty_graphics) return 0;
        return self.kitty.placements_generation;
    }

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
        /// The `row_data` index of the row.
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
            self.row_data.items(.applied_styles),
        ) |state, *cells, *applied| {
            var arena: ArenaAllocator = state.promote(alloc);
            arena.deinit();
            cells.deinit(alloc);
            applied.deinit(alloc);
        }
        self.row_data.deinit(alloc);
        self.pending_styles.deinit(alloc);
        self.kitty.deinit(alloc);
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

        // The overscan rows to capture beyond the viewport. The request
        // decides the layout of row_data, and the actual counts are
        // limited to the rows that exist. With no request, everything
        // below behaves exactly as it does without overscan.
        const above_req: usize = self.overscan_request.above;
        const below_req: usize = self.overscan_request.below;
        const row_data_len: usize = above_req + s.pages.rows + below_req;

        // The first captured row and how many rows above the viewport
        // we actually got.
        const top: struct { pin: PageList.Pin, above: usize } = if (above_req == 0)
            .{ .pin = viewport_pin, .above = 0 }
        else switch (viewport_pin.upOverflow(above_req)) {
            .offset => |p| .{ .pin = p, .above = above_req },
            .overflow => |o| .{ .pin = o.end, .above = above_req - o.remaining },
        };

        // How many rows below the viewport we actually get. The page list
        // ends at the last active row, so this is zero whenever the
        // viewport follows the active area. This is computed before the
        // loop below so that a change can force a redraw. When new output
        // appears below a scrolled viewport, it can land in an entry that
        // was never built or that held a different row.
        const below: usize = if (below_req == 0) 0 else below: {
            const bottom = viewport_pin.down(s.pages.rows - 1).?;
            break :below switch (bottom.downOverflow(below_req)) {
                .offset => below_req,
                .overflow => |o| below_req - o.remaining,
            };
        };

        // The index of top.pin in row_data.
        const first: usize = above_req - top.above;

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

            // If our row_data layout changed (overscan request changed),
            // we do a full rebuild.
            if (self.row_data.len != row_data_len) break :redraw true;

            // If the captured overscan changed, rows may have entered
            // row_data that were never built. This only happens when the
            // viewport is scrolled, so it's cheap to be safe.
            if (self.overscan.above != top.above or
                self.overscan.below != below) break :redraw true;

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

        // Ensure our row length is exactly our height plus requested
        // overscan, freeing or allocating data as necessary. In
        // most cases we'll have a perfectly matching size.
        if (self.row_data.len != row_data_len) {
            @branchHint(.unlikely);

            if (self.row_data.len < row_data_len) {
                // Resize our rows to the desired length, marking any added
                // values undefined.
                const old_len = self.row_data.len;
                try self.row_data.resize(alloc, row_data_len);

                // Initialize all our values. Its faster to use slice() + set()
                // because appendAssumeCapacity does this multiple times.
                var row_data = self.row_data.slice();
                for (old_len..row_data_len) |y| {
                    row_data.set(y, .{
                        .arena = .{},
                        .pin = undefined,
                        .serial = undefined,
                        .raw = undefined,
                        .cells = .empty,
                        .dirty = true,
                        .selection = null,
                        .highlights = .empty,
                        .placeholders = .empty,
                        .applied_styles = .empty,
                    });
                }
            } else {
                const row_data = self.row_data.slice();
                for (
                    row_data.items(.arena)[row_data_len..],
                    row_data.items(.cells)[row_data_len..],
                    row_data.items(.applied_styles)[row_data_len..],
                ) |state, *cell, *applied| {
                    var arena: ArenaAllocator = state.promote(alloc);
                    arena.deinit();
                    cell.deinit(alloc);
                    applied.deinit(alloc);
                }
                self.row_data.shrinkRetainingCapacity(row_data_len);
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
        const row_placeholders = row_data.items(.placeholders);
        const row_dirties = row_data.items(.dirty);
        const row_applied = row_data.items(.applied_styles);

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
            .placeholders = row_placeholders,
            .kitty_stale = &self.kitty.stale,
            .dirties = row_dirties,
            .pending_styles = &self.pending_styles,
            .applied_styles = row_applied,
        };
        const row_data_end: usize = first + top.above + self.rows + below;
        var y: usize = first;
        var any_dirty: bool = false;
        var page_it = top.pin.pageIterator(.right_down, null);
        while (y < row_data_end) {
            const chunk = page_it.next() orelse break;
            const node = chunk.node;
            const node_serial = node.serial;
            const p: *page.Page = node.page();

            // The number of rows we consume from this chunk. The chunk
            // may extend beyond what we capture (the viewport is always
            // exactly `rows` tall, plus any overscan) so we clamp.
            const take: usize = @min(
                @as(usize, chunk.end - chunk.start),
                row_data_end - y,
            );

            // Find our cursor if we haven't found it yet. We do this even
            // if rows are not dirty because the cursor is unrelated. We
            // can check the chunk bounds once rather than every row.
            if (self.cursor.viewport == null and
                node == s.cursor.page_pin.node)
            cursor: {
                const cy = s.cursor.page_pin.y;
                if (cy < chunk.start or cy >= chunk.start + take) break :cursor;

                // The cursor may be in an overscan row, in which case it
                // is not visible in the viewport.
                const idx = y + (cy - chunk.start);
                const vp_start = self.viewportStart();
                if (idx < vp_start or idx >= vp_start + self.rows) break :cursor;
                self.cursor.viewport = .{
                    .y = @intCast(idx - vp_start),
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
        assert(y == row_data_end);

        self.overscan = .{
            .above = @intCast(top.above),
            .below = @intCast(below),
        };

        // Work out what the Kitty placeholder runs draw. This must come
        // after setting the overscan above, because it reads the
        // captured rows.
        if (comptime build_options.kitty_graphics) try Kitty.update(
            self,
            alloc,
            t,
            redraw,
            any_dirty,
        );

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

            // Not cached since the cell contents may change.
            const br_pin: PageList.Pin = if (!sel.rectangle and
                cache.br_pin.rowAndCell().cell.wide == .spacer_head)
                cache.br_pin.rightWrap(1) orelse cache.br_pin
            else
                cache.br_pin;
            const br = s.pages.pointFromPin(.screen, br_pin).?.screen;

            // We need to determine if our selection is within the viewport.
            // The viewport is generally very small so the efficient way to
            // do this is to traverse the viewport pages and check for the
            // matching selection pages. Unused entries are skipped.
            const range = self.rowDataRange();
            for (
                row_pins[range.start..range.end],
                row_sels[range.start..range.end],
                row_dirties[range.start..range.end],
            ) |pin, *sel_bounds, *dirty| {
                const p = s.pages.pointFromPin(.screen, pin).?.screen;
                const row_sel = sel.containedRowCached(
                    s,
                    cache.tl_pin,
                    br_pin,
                    pin,
                    tl,
                    br,
                    p,
                ) orelse {
                    if (sel_bounds.* != null) {
                        sel_bounds.* = null;
                        dirty.* = true;
                        any_dirty = true;
                    }
                    continue;
                };
                const start = row_sel.start();
                const end = row_sel.end();
                assert(start.node == end.node);
                assert(start.x <= end.x);
                assert(start.y == end.y);

                const start_x = if (start.x > 0 and
                    start.rowAndCell().cell.wide == .spacer_tail)
                    start.x - 1
                else
                    start.x;

                sel_bounds.* = .{ start_x, end.x };
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
        const row_applied = row_data.items(.applied_styles);

        // Process the pending runs one row segment at a time. All the
        // runs for a row are appended contiguously by a single
        // beginUpdate, so a segment boundary is simply a change in y.
        const runs = self.pending_styles.items;
        var i: usize = 0;
        while (i < runs.len) {
            const y = runs[i].y;
            var j = i + 1;
            while (j < runs.len and runs[j].y == y) j += 1;
            const segment = runs[i..j];
            i = j;

            // Defensive: the row data may have changed shape if the
            // caller violated ordering (e.g. an error path skipped an
            // endUpdate between updates). Any update that changes
            // dimensions clears the pending list (redraw), so this
            // should never actually trigger, but the cost is trivial.
            if (y >= row_cells.len) continue;

            // If the segment matches the runs already denormalized
            // into this row's cell data then the per-cell styles are
            // already correct and the (comparatively large) fill can
            // be skipped entirely. This is the common case: rebuilt
            // rows usually keep their styling (only the text
            // changed), and full redraws of an unchanged screen keep
            // both.
            const applied = &row_applied[y];
            if (runsEql(applied.items, segment)) continue;

            for (segment) |run| {
                const styles = row_cells[run.y].slice().items(.style);
                const end = @min(run.end, styles.len);
                const start = @min(run.start, end);

                fillStyles(styles[start..end], run.style);
            }

            // Record what we applied so the next rebuild of this row
            // can skip the fill. beginUpdate reserved the capacity
            // (we cannot allocate here); if it doesn't fit (e.g.
            // segments merged across multiple begins without an end)
            // leave the cache empty, which never matches and simply
            // means the next rebuild applies its runs.
            applied.clearRetainingCapacity();
            if (applied.capacity >= segment.len) {
                applied.appendSliceAssumeCapacity(segment);
            }
        }
        self.pending_styles.clearRetainingCapacity();
    }

    /// Mark all render-state data as consumed by the renderer.
    ///
    /// This clears both the global dirty state and every per-row dirty flag.
    /// Callers that only consume part of a frame should clear the two layers
    /// individually instead.
    pub fn clean(self: *RenderState) void {
        self.dirty = .false;
        @memset(self.row_data.items(.dirty), false);
    }

    /// Returns the `row_data` index of the top row of the viewport.
    ///
    /// This is `overscan_request.above`, so it is zero without overscan
    /// and does not change from one update to the next. The viewport is
    /// the `rows` entries starting here.
    pub fn viewportStart(self: *const RenderState) usize {
        return self.overscan_request.above;
    }

    /// Converts a `row_data` index into a y position relative to the top
    /// of the viewport. Rows above the viewport are negative, and rows
    /// below it are `rows` or greater. For example, with one row of
    /// overscan above, index 0 is y = -1 and index 1 is y = 0.
    pub fn viewportY(self: *const RenderState, index: usize) isize {
        return @as(isize, @intCast(index)) - @as(isize, @intCast(self.viewportStart()));
    }

    /// A range of `row_data` indices. `start` is inclusive and `end` is
    /// exclusive, so it can be used directly as `range.start..range.end`.
    pub const RowDataRange = struct {
        start: usize,
        end: usize,
    };

    /// Returns the range of `row_data` that holds rows from the last
    /// update: the captured overscan rows above, the viewport, and the
    /// captured overscan rows below.
    ///
    /// Entries outside this range are unused. They contain leftover or
    /// uninitialized data and must not be read. Without overscan, this
    /// is always `0..rows`.
    pub fn rowDataRange(self: *const RenderState) RowDataRange {
        const vp = self.viewportStart();
        return .{
            .start = vp - self.overscan.above,
            .end = vp + self.rows + self.overscan.below,
        };
    }

    /// Fill a slice of styles with one value.
    ///
    /// This is equivalent to `@memset(dst, value)` but manually vectorized:
    /// `@memset` with a struct value lowers to a per-element field copy
    /// that reloads the source at every iteration because LLVM cannot
    /// prove the destination doesn't alias it. And, Zig 0.16 disables
    /// auto-vectorization due to an LLVM bug.
    ///
    /// This complexity is justified by accounting for ~10% of the endUpdate
    /// times under heavily styled cases.
    fn fillStyles(dst: []Style, value: Style) void {
        // Each element is written as two overlapping 16-byte vector
        // stores held in registers, which requires 16 <= size <= 32.
        const elem_size = @sizeOf(Style);
        comptime assert(elem_size >= 16 and elem_size <= 32);

        const V = @Vector(16, u8);
        const src: *align(@alignOf(Style)) const [elem_size]u8 = @ptrCast(&value);
        const lo = @as(*align(4) const V, @ptrCast(src[0..16])).*;
        const hi = @as(*align(1) const V, @ptrCast(src[elem_size - 16 ..][0..16])).*;

        const dst_bytes = std.mem.sliceAsBytes(dst);
        var off: usize = 0;
        for (0..dst.len) |_| {
            @as(*align(1) V, @ptrCast(dst_bytes[off..][0..16])).* = lo;
            @as(*align(1) V, @ptrCast(dst_bytes[off + elem_size - 16 ..][0..16])).* = hi;
            off += elem_size;
        }
    }

    /// Returns true if the two style run lists denormalize to
    /// identical per-cell style data. This is a semantic comparison
    /// (styles are compared field-wise, never by bytes, since padding
    /// is undefined).
    fn runsEql(a: []const StyleRun, b: []const StyleRun) bool {
        if (a.len != b.len) return false;
        for (a, b) |ar, br| {
            if (ar.start != br.start or
                ar.end != br.end or
                !ar.style.eql(br.style)) return false;
        }
        return true;
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
        const range = self.rowDataRange();
        for (
            row_arenas[range.start..range.end],
            row_pins[range.start..range.end],
            row_serials[range.start..range.end],
            row_highlights_slice[range.start..range.end],
            row_dirties[range.start..range.end],
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

    pub const StringMap = std.ArrayList(point.Coordinate);

    /// Convert the current render state contents to a UTF-8 encoded
    /// string written to the given writer. This will unwrap all the wrapped
    /// rows. This is useful for a minimal viewport search.
    ///
    /// This currently writes empty cell contents as \x00 and writes all
    /// blank lines. This is fine for our current usage (link search) but
    /// we can adjust this later.
    ///
    /// Only viewport rows are included, never overscan rows. The `y`
    /// values in `map` are viewport rows.
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
        // This only covers the viewport, never overscan rows.
        const row_slice = self.row_data.slice();
        const vp_start = self.viewportStart();
        const row_rows = row_slice.items(.raw)[vp_start..][0..self.rows];
        const row_cells = row_slice.items(.cells)[vp_start..][0..self.rows];

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
    ///
    /// Only viewport rows are searched, never overscan rows. Both the
    /// given point and the returned cells use viewport coordinates.
    pub fn linkCells(
        self: *const RenderState,
        alloc: Allocator,
        viewport_point: point.Coordinate,
    ) Allocator.Error!CellSet {
        var result: CellSet = .empty;
        errdefer result.deinit(alloc);

        // This only covers the viewport, never overscan rows.
        const row_slice = self.row_data.slice();
        const vp_start = self.viewportStart();
        const row_pins = row_slice.items(.pin)[vp_start..][0..self.rows];
        const row_cells = row_slice.items(.cells)[vp_start..][0..self.rows];

        // Our viewport point is sent in by the caller and can't be trusted.
        // If it is outside the valid area then just return empty because
        // we can't possibly have a link there.
        if (viewport_point.x >= self.cols or
            viewport_point.y >= self.rows) return result;

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

/// The Kitty graphics logic of the render state. See "Images" in the
/// `RenderState` docs for what it produces.
///
/// There are two kinds of work:
///
///   - Placeholder runs. Each row keeps its own runs (`Row.placeholders`),
///     and a run is looked up once, when its row is rebuilt.
///   - Every other placement. These are kept in two lists. `roots` holds
///     each placement with everything worked out except its position.
///     `placed` holds the positioned copies that the iterator returns.
///
/// Building `roots` means walking every placement in the image storage,
/// so it only happens when the storage or the cell size changes. Turning
/// `roots` into `placed` is cheap, so it happens whenever a placement may
/// have moved. For example, with one image at a fixed cell:
///
///   1. The program places the image. The storage generation changes, so
///      the next update builds `roots` with one entry, then positions it
///      into `placed`.
///   2. The user scrolls the viewport up by one row. The update positions
///      the same root again, and `placed` now has it one row lower. The
///      storage is not read.
///   3. The program prints text on an unrelated row. Fixed images don't
///      move when cells change, so the update keeps `placed` as it is.
///
/// Each update also works out whether the iterator's output changed, for
/// `RenderState.imagePlacementsGeneration`. The runs are easy, because a
/// run only changes when its row is rebuilt or when it is looked up
/// again. For `placed`, the update keeps the previous list in
/// `placed_prev` and compares the two. In the example, step 1 and step 2
/// change the value, and step 3 doesn't.
const Kitty = struct {
    /// The Kitty image storage key of a placement, or void when Kitty
    /// graphics are disabled.
    const PlacementKey = if (build_options.kitty_graphics)
        kitty_gfx.ImageStorage.PlacementKey
    else
        void;

    /// Information that only applies to Kitty graphics placements.
    /// Public as `RenderState.KittyPlacement`.
    pub const Placement = struct {
        kind: Kind,

        /// The placement ID, or zero if there isn't one. For a
        /// virtual run, this is the ID that the cells ask for. For a
        /// relative or fixed placement, this is the ID the program
        /// gave it.
        placement_id: u32,

        pub const Kind = lib.Enum(lib.target, &.{
            // Part of a virtual placement: one run of placeholder
            // cells in a single row. Its `rows` is always 1 and its
            // z-index is always -1.
            "virtual",

            // A placement that a program positioned relative to
            // another placement, its parent. The parent is either a
            // virtual or a fixed placement, possibly through a chain of
            // other relative placements.
            //
            // With a virtual parent, the position is measured from the
            // top-left corner of the parent's placeholder cells in the
            // captured rows. That is the leftmost column and the topmost
            // row that any of those cells use, which matches Kitty. If
            // none of the parent's cells are in the captured rows, the
            // relative placement is not reported.
            //
            // With a fixed parent, the position is measured from the
            // parent's cell, which is the cell its `x` and `y` report.
            // The relative placement is reported when any part of it is
            // in the captured rows, even if the parent isn't.
            "relative",

            // A placement at a cell on the screen. It scrolls with the
            // text, like a line of output would. Its z-index is the one
            // the program chose, so it can be in any layer.
            //
            // It is reported at full size when any part of it is in the
            // captured rows, so it may need to be clipped when drawn.
            "fixed",
        });
    };

    /// A run of neighboring Kitty graphics placeholder cells in one row
    /// that show one piece of one image.
    ///
    /// The fields up to `col` come from the cells and are set when the
    /// row is rebuilt. The rest are filled in by `beginUpdate`, which
    /// looks up the image and works out what to draw. Public as
    /// `RenderState.Placeholder`.
    pub const Placeholder = struct {
        /// The column of the first cell and the number of cells.
        x: size.CellCountInt,
        width: size.CellCountInt,

        /// The image and placement that the cells ask for. The cells
        /// encode these in their foreground and underline colors. A
        /// placement ID of zero means the image's virtual placement,
        /// whichever it is.
        image_id: u32,
        placement_id: u32,

        /// The piece of the image that the first cell shows. The image
        /// is divided into a grid of cells, and this is the row and
        /// column in that grid. Each following cell in the run shows the
        /// next column.
        row: u32,
        col: u32,

        /// Whether `beginUpdate` has looked at this run yet, and if so,
        /// whether it draws anything. `geometry` is only set when this
        /// is `visible`.
        state: State = .stale,

        /// The virtual placement this run shows, or null if there is
        /// none. Not set while `state` is `stale`.
        target: ?PlacementKey = null,

        /// What to draw. Only set when `state` is `visible`.
        geometry: Geometry = undefined,

        pub const State = enum(u8) {
            /// The run is new and hasn't been looked at yet.
            stale,

            /// There is nothing to draw, for example because the image
            /// doesn't exist or hasn't been fully received.
            hidden,

            /// The run draws part of an image, described by `geometry`.
            visible,
        };

        /// What a visible run draws. The fields have the same meaning
        /// as the fields of the same name in `RenderState.ImagePlacement`.
        pub const Geometry = struct {
            image_generation: u64,
            offset_x: u32,
            offset_y: u32,
            width: u32,
            height: u32,
            source_x: u32,
            source_y: u32,
            source_width: u32,
            source_height: u32,
        };
    };

    /// The Kitty graphics state of a render state (`RenderState.kitty`).
    const Data = struct {
        /// The image storage generation, the terminal size in pixels,
        /// and the grid size when `roots` was last built. If any of
        /// these change, `roots` is built again and every run is looked
        /// up again. Together the pixel and grid sizes give the cell
        /// size.
        generation: u64 = 0,
        width_px: u32 = 0,
        height_px: u32 = 0,
        rows: size.CellCountInt = 0,
        cols: size.CellCountInt = 0,

        /// The image storage `dirty` counter when `placed` was last
        /// built. The storage changes this counter whenever placements
        /// may have moved, for example when a program scrolls part of
        /// the screen. If it changed but the generation didn't, `placed`
        /// is built again from the same `roots`.
        dirty: u64 = 0,

        /// True if the placeholder runs changed since the last update.
        /// The row builder sets it in two cases:
        ///
        ///   - A row was rebuilt with runs. The new runs are `stale` and
        ///     must be looked up.
        ///   - A row that had runs was rebuilt, and its old runs were
        ///     dropped. There is nothing to look up, but the iterator
        ///     no longer returns those runs.
        ///
        /// Updates where this is false and nothing else changed can skip
        /// the slow path.
        stale: bool = false,

        /// The placements that aren't placeholder runs, with everything
        /// except their position worked out. Built again only when
        /// `generation`, the pixel size, or the grid size change. A
        /// redraw alone, such as a viewport scroll, keeps it.
        roots: std.ArrayList(Root) = .empty,

        /// The number of `roots` positioned from placeholder cells (a
        /// `virtual` anchor). These move when cells change, so an
        /// update with rebuilt rows must position them again. When this
        /// is zero, rebuilt rows can't move anything in `placed`.
        virtual_anchors: u32 = 0,

        /// The captured rows grouped by the page they are on, top to
        /// bottom. This lets `rowIndexOfPin` find the row of a pin
        /// without walking the page list. It is built from the captured
        /// row pins each time `placed` is built, and only when some root
        /// has a `pin` anchor.
        chunks: std.ArrayList(Chunk) = .empty,

        /// The placements positioned by the last update that aren't
        /// placeholder runs. The image placement iterator returns these
        /// after the runs.
        placed: std.ArrayList(RenderState.ImagePlacement) = .empty,

        /// The previous contents of `placed`, so that an update can tell
        /// whether `placed` changed. `placeRoots` swaps the two lists
        /// instead of copying, so both keep their memory and a steady
        /// stream of updates doesn't allocate.
        placed_prev: std.ArrayList(RenderState.ImagePlacement) = .empty,

        /// The value returned by `RenderState.imagePlacementsGeneration`.
        /// `updateSlow` adds one to it, wrapping around, when the
        /// iterator's output may have changed.
        placements_generation: u64 = 0,

        fn deinit(self: *Data, alloc: Allocator) void {
            self.roots.deinit(alloc);
            self.chunks.deinit(alloc);
            self.placed.deinit(alloc);
            self.placed_prev.deinit(alloc);
        }
    };

    /// A placement that isn't a placeholder run, with everything except
    /// its position worked out. Its position is its anchor's position
    /// plus the offsets. For example, a relative placement 2 columns
    /// right of a virtual placement whose cells start at column 5 is
    /// drawn at column 7.
    const Root = struct {
        /// What the placement is positioned from.
        anchor: Anchor,

        /// The offset in cells from the anchor to the placement. For a
        /// relative placement, this adds up the offsets of every
        /// placement in its chain of parents. Zero for fixed placements.
        horizontal_offset: i32,
        vertical_offset: i32,

        /// The placement, with `x` and `y` not yet set.
        placement: RenderState.ImagePlacement,
    };

    /// What a root is positioned from.
    const Anchor = union(enum) {
        /// The placeholder cells of a virtual placement. The position is
        /// the smallest column and the smallest row of its runs in the
        /// captured rows.
        virtual: PlacementKey,

        /// The cell of a fixed placement, as the pin that the image
        /// storage keeps for it. A fixed placement uses its own pin. A
        /// relative placement uses the pin of the fixed placement at the
        /// start of its chain. The page list moves this pin as text
        /// moves, so it is always current.
        ///
        /// The pointer is owned by the image storage. It is only read
        /// during `beginUpdate`, and only while the storage generation
        /// matches `Data.generation`. Removing a placement always changes
        /// the generation, so the pointer is never read after the pin is
        /// freed.
        pin: *const PageList.Pin,
    };

    /// Neighboring captured rows that are on the same page. See
    /// `Data.chunks`.
    ///
    /// For example, if the captured rows are rows 98 and 99 of page A
    /// followed by rows 0 to 2 of page B, there are two chunks:
    /// `{ A, start 98, index 0 }` and `{ B, start 0, index 2 }`.
    const Chunk = struct {
        /// The page and the row within it of the chunk's first row.
        node: *PageList.List.Node,
        start: size.CellCountInt,

        /// The position of the chunk's first row among the captured
        /// rows, where 0 is the first captured row. This is not a
        /// `row_data` index. Add `rowDataRange().start` to get one.
        index: isize,
    };

    /// Work out what each placeholder run in the captured rows draws, and
    /// position every placement that isn't a placeholder run. This is
    /// part of `beginUpdate` and needs access to the terminal. `redraw`
    /// and `any_dirty` say whether every row or some rows were rebuilt.
    ///
    /// Most updates return after a few comparisons. The work is done by
    /// `updateSlow` only when something may have changed:
    ///
    ///   - The storage or the cell size changed. Build `roots` again and
    ///     look up every run.
    ///   - Rebuilt rows have new runs. Look up only those runs.
    ///   - Placements may have moved, because the viewport moved, the
    ///     storage `dirty` counter changed, or rebuilt rows can move a
    ///     placement positioned from placeholder cells. Build `placed`
    ///     again from `roots`.
    fn update(
        state: *RenderState,
        alloc: Allocator,
        t: *const Terminal,
        redraw: bool,
        any_dirty: bool,
    ) Allocator.Error!void {
        const storage = &t.screens.active.kitty_images;

        // `roots` and what a run draws depend only on the image storage
        // and the cell size. Switching to the other screen is caught
        // too, because no two storages share a generation.
        //
        // This runs on every update, so the common case (no images and
        // nothing changed) must stay a few comparisons. A redraw alone,
        // such as a viewport scroll, must not build `roots` again. A
        // change in rows or columns always causes a redraw, so those are
        // only compared on redraws.
        const roots_stale = state.kitty.generation != storage.generation or
            state.kitty.width_px != t.width_px or
            state.kitty.height_px != t.height_px or
            (redraw and (state.kitty.rows != state.rows or
                state.kitty.cols != state.cols));
        if (!roots_stale and !state.kitty.stale) {
            @branchHint(.likely);

            // No runs to look up. Placements only move when the viewport
            // moves, when the storage says that they moved, or (for
            // placements positioned from placeholder cells) when rows
            // are rebuilt.
            if (state.kitty.roots.items.len == 0) return;
            if (!redraw and state.kitty.dirty == storage.dirty and
                !(any_dirty and state.kitty.virtual_anchors > 0)) return;
        }

        try @call(
            .never_inline,
            updateSlow,
            .{ state, alloc, t, roots_stale },
        );
    }

    /// The part of `update` that does the work. It is kept out of line
    /// so that the common case in `update` stays small. `roots_stale` is
    /// true when `roots` must be built again.
    fn updateSlow(
        state: *RenderState,
        alloc: Allocator,
        t: *const Terminal,
        roots_stale: bool,
    ) Allocator.Error!void {
        const storage = &t.screens.active.kitty_images;
        if (roots_stale) {
            state.kitty.generation = storage.generation;
            state.kitty.width_px = t.width_px;
            state.kitty.height_px = t.height_px;
            state.kitty.rows = state.rows;
            state.kitty.cols = state.cols;
            try rebuildRoots(state, alloc, t);
        }

        // Whether the runs that the iterator returns changed. They did if
        // the row builder added or dropped runs, or if the loop below
        // looks up any run again, since its result may differ.
        var runs_changed = state.kitty.stale;
        if (roots_stale or state.kitty.stale) {
            state.kitty.stale = false;
            const cell_width: u32 = t.width_px / state.cols;
            const cell_height: u32 = t.height_px / state.rows;
            const row_data = state.row_data.slice();
            const row_pins = row_data.items(.pin);
            const row_placeholders = row_data.items(.placeholders);
            const range = state.rowDataRange();
            for (
                row_pins[range.start..range.end],
                row_placeholders[range.start..range.end],
            ) |pin, runs| {
                for (runs.items) |*run| {
                    if (!roots_stale and run.state != .stale) continue;
                    runs_changed = true;
                    resolvePlaceholder(
                        storage,
                        pin,
                        run,
                        cell_width,
                        cell_height,
                    );
                }
            }
        }

        try placeRoots(state, alloc);
        state.kitty.dirty = storage.dirty;

        // Tell consumers to read the iterator again if anything it
        // returns may be different. Rebuilding `roots` alone doesn't
        // count: if no run was looked up and `placed` is the same, the
        // output is the same.
        if (runs_changed or !placedEql(
            state.kitty.placed.items,
            state.kitty.placed_prev.items,
        )) state.kitty.placements_generation +%= 1;
    }

    /// Returns true if two lists hold the same placements in the same
    /// order.
    fn placedEql(
        a: []const RenderState.ImagePlacement,
        b: []const RenderState.ImagePlacement,
    ) bool {
        if (a.len != b.len) return false;
        for (a, b) |pa, pb| if (!std.meta.eql(pa, pb)) return false;
        return true;
    }

    /// Build `state.kitty.placed` from `state.kitty.roots`: position each
    /// root, and keep the ones with any part in the captured rows. This
    /// never reads the image storage, so it is cheap enough to run on
    /// every scroll. The old contents of `placed` move to `placed_prev`.
    fn placeRoots(
        state: *RenderState,
        alloc: Allocator,
    ) Allocator.Error!void {
        std.mem.swap(
            std.ArrayList(RenderState.ImagePlacement),
            &state.kitty.placed,
            &state.kitty.placed_prev,
        );
        state.kitty.placed.clearRetainingCapacity();
        if (state.kitty.roots.items.len == 0) return;

        const range = state.rowDataRange();
        const captured_len: isize = @intCast(range.end - range.start);
        const captured_placeholders = state.row_data.items(.placeholders)[range.start..range.end];
        const viewport_y_base = state.viewportY(range.start);

        // Group the captured rows by page, for `rowIndexOfPin`. Only
        // `pin` anchors need this.
        state.kitty.chunks.clearRetainingCapacity();
        if (state.kitty.virtual_anchors < state.kitty.roots.items.len) {
            const captured_pins = state.row_data.items(.pin)[range.start..range.end];
            try state.kitty.chunks.ensureTotalCapacity(alloc, captured_pins.len);
            for (captured_pins, 0..) |pin, i| {
                if (i > 0 and captured_pins[i - 1].node == pin.node) continue;
                state.kitty.chunks.appendAssumeCapacity(.{
                    .node = pin.node,
                    .start = pin.y,
                    .index = @intCast(i),
                });
            }
        }

        for (state.kitty.roots.items) |root| {
            const p = root.placement;

            // Where the anchor is. `y` counts captured rows, where 0 is
            // the first captured row.
            const origin: struct { x: i64, y: i64 } = switch (root.anchor) {
                // The top-left corner of the virtual placement's cells:
                // the smallest column and the smallest row of those
                // cells. Without any of those cells in the captured rows,
                // the placement isn't drawn, which matches Kitty. There
                // are rarely more than a few of these, so a simple scan of
                // the runs for each one is fine.
                .virtual => |key| origin: {
                    var origin: ?struct { x: i64, y: i64 } = null;
                    for (captured_placeholders, 0..) |runs, y| {
                        for (runs.items) |run| {
                            const target = run.target orelse continue;
                            if (!target.eql(key)) continue;
                            if (origin) |*o| {
                                o.x = @min(o.x, run.x);
                                o.y = @min(o.y, @as(i64, @intCast(y)));
                            } else origin = .{ .x = run.x, .y = @intCast(y) };
                        }
                    }
                    const o = origin orelse continue;
                    break :origin .{ .x = o.x, .y = o.y };
                },

                // The pin's cell. A pin is marked garbage when its row
                // is removed from the scrollback. It has no position
                // then, so the placement isn't drawn.
                .pin => |pin| origin: {
                    if (pin.garbage) continue;
                    const y = rowIndexOfPin(
                        state.kitty.chunks.items,
                        pin.*,
                        captured_len,
                        p.rows,
                        root.vertical_offset,
                    ) orelse continue;
                    break :origin .{ .x = pin.x, .y = y };
                },
            };

            // The top-left cell, which can be above or left of the
            // captured rows. Placements are reported at full size, so
            // keep any with at least one cell in the captured rows.
            const x: i64 = origin.x + root.horizontal_offset;
            const y: i64 = origin.y + root.vertical_offset;
            if (y + p.rows - 1 < 0 or y >= captured_len) continue;
            if (x + p.cols - 1 < 0 or x >= state.cols) continue;

            var positioned = p;
            positioned.x = std.math.cast(i32, x) orelse continue;
            positioned.y = std.math.cast(i32, viewport_y_base + y) orelse continue;
            try state.kitty.placed.append(alloc, positioned);
        }
    }

    /// Returns the row of a pin, counted in captured rows where 0 is the
    /// first captured row. The result is negative for rows above the
    /// captured rows and `captured_len` or more for rows below them.
    ///
    /// `rows` and `vertical_offset` describe the placement that the pin
    /// anchors: it starts `vertical_offset` rows below the pin and is
    /// `rows` tall. If that placement can't reach the captured rows, the
    /// search may stop early and return null.
    ///
    /// For example, with 5 captured rows and a placement 3 rows tall:
    ///
    ///   - A pin 2 rows above the first captured row returns -2. The
    ///     placement covers rows -2 to 0, so its last row is visible.
    ///   - A pin 10 rows above it may return null, because the placement
    ///     ends at row -8.
    ///
    /// Pins on captured pages are found with the chunk table alone. Other
    /// pins are found by walking the pages above or below. This is much
    /// cheaper than `pointFromPin`, which counts rows from the top of the
    /// scrollback. It reads page list nodes, so it is only safe while
    /// the terminal can't change, such as during `beginUpdate`.
    fn rowIndexOfPin(
        chunks: []const Chunk,
        pin: PageList.Pin,
        captured_len: isize,
        rows: u32,
        vertical_offset: i32,
    ) ?isize {
        if (chunks.len == 0) return null;

        // A pin on a page with captured rows. This also covers pins on
        // rows of those pages that aren't captured.
        for (chunks) |chunk| {
            if (chunk.node != pin.node) continue;
            return chunk.index + @as(isize, pin.y) - @as(isize, chunk.start);
        }

        // A pin on a page above the captured rows. The placement's last
        // row is the pin's row plus `reach`, so it is only visible when
        // the pin's row is -reach or more. Walk up a page at a time, and
        // stop once a page's last row is too far up. `bottom` is the
        // last row of the page being checked.
        const reach: isize = @as(isize, @intCast(rows)) - 1 + @max(0, vertical_offset);
        const first = chunks[0];
        var bottom: isize = first.index - @as(isize, first.start) - 1;
        var node = first.node.prev;
        while (node) |n| : (node = n.prev) {
            if (bottom < -reach) break;
            const top = bottom - (@as(isize, n.rows()) - 1);
            if (n == pin.node) return top + pin.y;
            bottom = top - 1;
        }

        // A pin on a page below the captured rows. Only a negative
        // offset can move such a placement up into them. Its first row
        // is the pin's row plus the offset, which must be less than
        // `captured_len`. Walk down a page at a time, and stop once a
        // page's first row is too far down. `top` is the first row of
        // the page being checked.
        if (vertical_offset >= 0) return null;
        const last = chunks[chunks.len - 1];
        var top: isize = last.index - @as(isize, last.start) + last.node.rows();
        node = last.node.next;
        while (node) |n| : (node = n.next) {
            if (top + vertical_offset >= captured_len) break;
            if (n == pin.node) return top + pin.y;
            top += n.rows();
        }

        return null;
    }

    /// Build `state.kitty.roots` again from the image storage. Everything
    /// about a root except its position depends only on the storage and
    /// the cell size, so this only runs when one of those changes. It
    /// visits every placement in the storage.
    fn rebuildRoots(
        state: *RenderState,
        alloc: Allocator,
        t: *const Terminal,
    ) Allocator.Error!void {
        const storage = &t.screens.active.kitty_images;
        state.kitty.roots.clearRetainingCapacity();
        state.kitty.virtual_anchors = 0;
        var it = storage.placements.iterator();
        while (it.next()) |kv| {
            // Keep placements with garbage pins. A pin can become
            // garbage without a generation change, so `placeRoots`
            // checks for it every time instead.
            const root: Root = switch (kv.value_ptr.location) {
                .pin => |pin| .{
                    .anchor = .{ .pin = pin },
                    .horizontal_offset = 0,
                    .vertical_offset = 0,
                    .placement = template(
                        storage,
                        t,
                        kv.key_ptr.*,
                        kv.value_ptr,
                        .fixed,
                    ) orelse continue,
                },

                .virtual => continue,

                .relative => |rel| root: {
                    // Follow the chain of parents to the placement at its
                    // start. A broken chain is never drawn.
                    const chain = storage.resolveChain(rel) orelse continue;
                    break :root .{
                        .anchor = switch (chain.root.location) {
                            .virtual => .{ .virtual = chain.root_key },
                            .pin => |pin| .{ .pin = pin },

                            // resolveChain roots are never relative.
                            .relative => unreachable,
                        },
                        .horizontal_offset = chain.horizontal_offset,
                        .vertical_offset = chain.vertical_offset,
                        .placement = template(
                            storage,
                            t,
                            kv.key_ptr.*,
                            kv.value_ptr,
                            .relative,
                        ) orelse continue,
                    };
                },
            };

            try state.kitty.roots.append(alloc, root);
            if (root.anchor == .virtual) state.kitty.virtual_anchors += 1;
        }
    }

    /// Returns the `ImagePlacement` for a placement in the image storage,
    /// with everything except `x` and `y` filled in. Returns null if
    /// there is nothing to draw, such as when the image is missing, still
    /// loading, or the terminal has no cell size in pixels.
    fn template(
        storage: *const kitty_gfx.ImageStorage,
        t: *const Terminal,
        key: PlacementKey,
        p: *const kitty_gfx.ImageStorage.Placement,
        kind: Placement.Kind,
    ) ?RenderState.ImagePlacement {
        // Nothing to draw until the displayed pixels arrive. For an
        // animation, those are the current frame's pixels.
        const image = storage.imageById(key.image_id) orelse return null;
        if (image.renderData().isPending()) return null;

        // The size is zero when the terminal has no cell size in pixels.
        // Then there is nothing to draw.
        const grid = p.gridSize(image, t);
        if (grid.cols == 0 or grid.rows == 0) return null;
        const dest = p.pixelSize(image, t);
        if (dest.width == 0 or dest.height == 0) return null;
        const offset = p.cellOffset(t);
        const source = p.sourceRect(image);

        return .{
            .protocol = .{ .kitty = .{
                .kind = kind,
                .placement_id = switch (key.placement_id.tag) {
                    .external => key.placement_id.id,
                    .internal => 0,
                },
            } },
            .image_id = key.image_id,
            .image_generation = image.generation,
            .layer = RenderState.imageLayerFromZ(p.z),
            .z = p.z,
            .x = 0,
            .y = 0,
            .cols = grid.cols,
            .rows = grid.rows,
            .offset_x = offset.x,
            .offset_y = offset.y,
            .width = dest.width,
            .height = dest.height,
            .source_x = source.x,
            .source_y = source.y,
            .source_width = source.width,
            .source_height = source.height,
        };
    }

    /// Look up what one placeholder run draws and store it in the run.
    /// `row_pin` is the pin of the run's row.
    fn resolvePlaceholder(
        storage: *const kitty_gfx.ImageStorage,
        row_pin: PageList.Pin,
        run: *Placeholder,
        cell_width: u32,
        cell_height: u32,
    ) void {
        run.state = .hidden;
        run.target = null;

        // Remember the virtual placement even if the image can't be
        // drawn. Relative placements attached to it still need the
        // position of these cells.
        const target = storage.placeholderTarget(
            run.image_id,
            run.placement_id,
        ) orelse return;
        run.target = target.key;

        // Nothing to draw until the displayed pixels arrive, as in
        // `template`.
        const image = storage.imageById(run.image_id) orelse return;
        if (image.renderData().isPending()) return;

        // Without a cell size in pixels, there is no size to draw at.
        if (cell_width == 0 or cell_height == 0) return;

        var pin = row_pin;
        pin.x = run.x;
        const vp: kitty_gfx.unicode.Placement = .{
            .pin = pin,
            .image_id = run.image_id,
            .placement_id = run.placement_id,
            .col = run.col,
            .row = run.row,
            .width = run.width,
            .height = 1,
        };
        const rp = vp.renderPlacement(
            &target.placement,
            &image,
            cell_width,
            cell_height,
        ) catch |err| {
            log.warn("error resolving virtual placement err={}", .{err});
            return;
        };
        if (rp.dest_width == 0 or rp.dest_height == 0) return;

        run.geometry = .{
            .image_generation = image.generation,
            .offset_x = rp.offset_x,
            .offset_y = rp.offset_y,
            .width = rp.dest_width,
            .height = rp.dest_height,
            .source_x = rp.source_x,
            .source_y = rp.source_y,
            .source_width = rp.source_width,
            .source_height = rp.source_height,
        };
        run.state = .visible;
    }

    /// Groups Kitty placeholder cells into runs as the row scan visits
    /// them. Feed it placeholder cells from left to right. A gap between
    /// two cells (any cell that isn't fed) ends the current run.
    const PlaceholderDecoder = struct {
        list: *std.ArrayList(RenderState.Placeholder),
        alloc: Allocator,
        stale: *bool,
        run: ?kitty_gfx.unicode.IncompletePlacement = null,
        start: usize = 0,
        end: usize = 0,

        inline fn feed(
            self: *PlaceholderDecoder,
            x: usize,
            style: *const Style,
            cps: []const u21,
        ) Allocator.Error!void {
            const curr: kitty_gfx.unicode.IncompletePlacement = .init(style, cps);
            if (self.run) |*prev| {
                if (x == self.end and prev.append(&curr)) {
                    self.end += 1;
                    return;
                }
                try self.flush();
            }
            self.run = curr.start();
            self.start = x;
            self.end = x + 1;
        }

        fn flush(self: *PlaceholderDecoder) Allocator.Error!void {
            const run = self.run orelse return;
            self.run = null;
            self.stale.* = true;
            try self.list.append(self.alloc, .{
                .x = @intCast(self.start),
                .width = @intCast(run.width),
                .image_id = run.imageId(),
                .placement_id = run.placement_id orelse 0,
                .row = run.row.?,
                .col = run.col.?,
            });
        }
    };
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
    placeholders: []std.ArrayList(RenderState.Placeholder),
    kitty_stale: *bool,
    dirties: []bool,
    pending_styles: *std.ArrayList(RenderState.StyleRun),
    applied_styles: []std.ArrayList(RenderState.StyleRun),

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
            // Dropping this row's runs changes what the image placement
            // iterator returns, so tell the Kitty update. Only a row
            // that had placeholder cells can have runs. Checking that
            // flag first means other rows never read their run list.
            if (comptime build_options.kitty_graphics) {
                if (b.raws[vy].kitty_virtual_placeholder and
                    b.placeholders[vy].items.len > 0) b.kitty_stale.* = true;
            }
            b.placeholders[vy] = .empty;
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
        if (cells.len != b.cols) {
            // The cell storage (including the per-cell style data) is
            // being reallocated, so the applied style cache no longer
            // describes it. Clear it before the resize so an error
            // can't leave it stale.
            b.applied_styles[vy].clearRetainingCapacity();
            try cells.resize(b.alloc, b.cols);
        }

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
        // Rows with Kitty placeholders are rare. They get their own copy
        // of the scan below, so other rows pay nothing for them. These
        // rows are scanned even without managed memory, because a
        // placeholder cell can be a plain character with no style.
        const placeholder_row = build_options.kitty_graphics and
            page_row.kitty_virtual_placeholder;
        if (!page_row.managedMemory() and !placeholder_row) return;

        const arena_alloc = arena.allocator();
        if (placeholder_row) {
            @branchHint(.unlikely);
            var decoder: Kitty.PlaceholderDecoder = .{
                .list = &b.placeholders[vy],
                .alloc = arena_alloc,
                .stale = b.kitty_stale,
            };
            try b.scan(true, p, page_cells, cells_slice, arena_alloc, vy, &decoder);
            try decoder.flush();
            return;
        }

        try b.scan(false, p, page_cells, cells_slice, arena_alloc, vy, {});
    }

    /// The managed memory scan of `row`. When `placeholders` is true,
    /// this also feeds every Kitty placeholder cell to the decoder.
    ///
    /// This is deliberately not inline. Each value of `placeholders`
    /// produces its own function, so the placeholder handling can't
    /// change how the common version (without placeholders) is
    /// optimized.
    fn scan(
        b: *const RowBuilder,
        comptime placeholders: bool,
        p: *page.Page,
        page_cells: []const page.Cell,
        cells_slice: std.MultiArrayList(RenderState.Cell).Slice,
        arena_alloc: Allocator,
        vy: usize,
        decoder: if (placeholders) *Kitty.PlaceholderDecoder else void,
    ) Allocator.Error!void {
        const cells_grapheme = cells_slice.items(.grapheme);
        const n = page_cells.len;
        const runs_start = b.pending_styles.items.len;
        var x: usize = 0;
        scan: while (x < n) {
            // Skip runs of plain cells a group at a time. Cells that
            // need managed handling are often rare even within rows that
            // have managed memory (e.g. a row is "styled" if a single
            // cell has a style) so groups are skipped with a few vector
            // operations. On placeholder rows a plain cell can be a
            // placeholder, so those rows check each cell instead.
            if (!placeholders) while (n - x >= CellSpecialMask.group_len) {
                if (!CellSpecialMask.match(page_cells, x)) break;
                x += CellSpecialMask.group_len;
            };

            // Scalar scan to the next special cell.
            while (true) {
                if (x >= n) break :scan;
                if (!CellSpecialMask.matchScalar(page_cells[x])) break;
                if (placeholders and
                    page_cells[x].codepoint() == kitty_gfx.unicode.placeholder)
                {
                    try decoder.feed(x, &.{}, &.{});
                }
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

                    // A placeholder can leave out its row and column
                    // (it then continues the run to its left), which
                    // makes it a plain styled cell like these. Every
                    // cell in this style run has the same style.
                    if (placeholders) for (start..x) |px| {
                        if (page_cells[px].codepoint() != kitty_gfx.unicode.placeholder) continue;
                        try decoder.feed(px, &style_val, &.{});
                    };
                },

                // If we have a multi-codepoint grapheme, look it up and
                // set our content type. Note grapheme cells may also
                // be styled. The style must be recorded as a run (rather
                // than written directly) so that it is ordered correctly
                // relative to possibly-stale runs from prior updates.
                .codepoint_grapheme => {
                    const style_val: Style = if (page_cell.style_id > 0) style: {
                        const style_val = p.styles.get(
                            p.memory,
                            page_cell.style_id,
                        ).*;
                        try b.pending_styles.append(b.alloc, .{
                            .y = @intCast(vy),
                            .start = @intCast(x),
                            .end = @intCast(x + 1),
                            .style = style_val,
                        });
                        break :style style_val;
                    } else .{};
                    const cps = try arena_alloc.dupe(
                        u21,
                        p.lookupGrapheme(page_cell) orelse &.{},
                    );
                    cells_grapheme[x] = cps;

                    // Most placeholders give their row and column in
                    // the image as combining characters, so most are
                    // handled here, using the style and grapheme we
                    // already have.
                    if (placeholders and
                        page_cell.codepoint() == kitty_gfx.unicode.placeholder)
                    {
                        try decoder.feed(x, &style_val, cps);
                    }
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
                            .palette = page_cell.content.color_palette.data,
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

        // Reserve the applied style cache capacity for the runs we
        // appended so that endUpdate (which cannot allocate) is able
        // to record what it applies. See Row.applied_styles.
        const runs_added = b.pending_styles.items.len - runs_start;
        if (runs_added > 0) try b.applied_styles[vy].ensureTotalCapacity(
            b.alloc,
            runs_added,
        );
    }
};

test "styled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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

    // Unused entries (outside rowDataRange) may hold anything, so
    // we only compare the populated range.
    try testing.expectEqual(fresh.overscan, incremental.overscan);
    try testing.expectEqual(fresh.rowDataRange(), incremental.rowDataRange());
    const range = fresh.rowDataRange();

    const inc_data = incremental.row_data.slice();
    const new_data = fresh.row_data.slice();
    try testing.expectEqual(new_data.len, inc_data.len);
    for (range.start..range.end) |y| {
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
    try testIncrementalMatchesFresh(.{});
}

test "incremental updates match full rebuild with overscan" {
    try testIncrementalMatchesFresh(.{ .above = 2, .below = 1 });
}

fn testIncrementalMatchesFresh(request: RenderState.Overscan) !void {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Deterministic so failures are reproducible.
    var prng = std.Random.DefaultPrng.init(0xB0BA_CAFE);
    const rand = prng.random();

    var t = try Terminal.init(io, alloc, .{
        .cols = 20,
        .rows = 8,
        .max_scrollback_bytes = 500,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var inc: RenderState = .empty;
    defer inc.deinit(alloc);
    inc.overscan_request = request;

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
                5 => s.nextSlice(try std.mem.print(&buf, "\x1b[{};{}H", .{
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
                8 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}L", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                9 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}M", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),

                // Scroll up/down (page-dirty row rotations).
                10 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}S", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                11 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}T", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),

                // Set/reset scroll regions to exercise bounded scrolls.
                12 => {
                    const top = rand.intRangeAtMost(u16, 1, 4);
                    const bot = rand.intRangeAtMost(u16, top + 1, 8);
                    s.nextSlice(try std.mem.print(
                        &buf,
                        "\x1b[{};{}r",
                        .{ top, bot },
                    ));
                },

                // Insert/delete/erase chars within a row.
                13 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}@", .{
                    rand.intRangeAtMost(u16, 1, 5),
                })),
                14 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}P", .{
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
        fresh.overscan_request = request;
        try fresh.update(alloc, &t);

        try testCompareStates(&inc, &fresh);
    }
}

test "begin and end update" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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

test "endUpdate skips unchanged style runs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mAB"); // Bold

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // The applied cache should record the bold run for row 0.
    {
        const row_data = state.row_data.slice();
        const applied = row_data.items(.applied_styles);
        try testing.expectEqual(1, applied[0].items.len);
        try testing.expect(applied[0].items[0].style.flags.bold);
        try testing.expect(state.row_data.items(.cells)[0].get(0).style.flags.bold);
    }

    // Rewrite the text without changing the styling: the row is
    // rebuilt, the run matches the cache, and the styles must remain
    // correct (the fill is skipped internally).
    s.nextSlice("\x1b[1;1H\x1b[1mXY");
    try state.update(alloc, &t);
    {
        const cells = &state.row_data.items(.cells)[0];
        try testing.expectEqual('X', cells.get(0).raw.codepoint());
        try testing.expect(cells.get(0).style.flags.bold);
        try testing.expect(cells.get(1).style.flags.bold);
    }

    // Change the styling: the cache mismatches and the new styles
    // must be applied and recorded.
    s.nextSlice("\x1b[1;1H\x1b[0;3mZW"); // Italic
    try state.update(alloc, &t);
    {
        const cells = &state.row_data.items(.cells)[0];
        try testing.expectEqual('Z', cells.get(0).raw.codepoint());
        try testing.expect(!cells.get(0).style.flags.bold);
        try testing.expect(cells.get(0).style.flags.italic);

        const applied = state.row_data.items(.applied_styles);
        try testing.expectEqual(1, applied[0].items.len);
        try testing.expect(applied[0].items[0].style.flags.italic);
    }
}

test "bg color cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t: Terminal = try .init(io, alloc, .{
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
    const io = testing.io;

    var t: Terminal = try .init(io, alloc, .{
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

test "selection starting on wide char spacer tail" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Wide char at x=1 with its spacer tail at x=2.
    s.nextSlice("a宽b");

    // Start on the spacer tail, as when selecting from the right.
    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 1, 3 }, &sels[0].?);
    try testing.expectEqual(null, sels[1]);
}

test "selection ending on wide char spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // The wide char wraps, leaving a spacer head at x=9.
    // Position the cursor before rendering so overwriting the spacer
    // head won't dirty the following row through cursor movement.
    s.nextSlice("abcdefghi宽\x1b[1;10H");

    // Select up to and including the spacer head.
    const screen: *Screen = t.screens.active;
    const sel: Selection = .init(
        screen.pages.pin(.{ .active = .{ .x = 7, .y = 0 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 9, .y = 0 } }).?,
        false,
    );

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // A rectangle selection doesn't unwrap so it doesn't extend.
    try screen.select(.init(sel.start(), sel.end(), true));
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    const dirty = row_data.items(.dirty);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 7, 9 }, &sels[0].?);
    try testing.expectEqual(null, sels[1]);

    // A normal selection includes the wrapped wide char.
    try screen.select(sel);
    try state.update(alloc, &t);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 7, 9 }, &sels[0].?);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 0, 0 }, &sels[1].?);
    try testing.expectEqual(null, sels[2]);

    // Removing the spacer head must unselect and redraw the following row.
    state.clean();
    s.nextSlice("Z");
    try state.update(alloc, &t);
    try testing.expectEqual(null, sels[1]);
    try testing.expect(dirty[1]);
    try testing.expect(!dirty[2]);
}

test "linkCells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    const viewport_rows: size.CellCountInt = 10;
    const tail_rows: size.CellCountInt = 5;

    var t = try Terminal.init(io, alloc, .{
        .cols = page.std_capacity.cols,
        .rows = viewport_rows,
        .max_scrollback_bytes = 10_000,
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
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

/// Writes lines "0", "1", ... up to `n - 1` into the terminal, each
/// followed by a newline, so the cursor ends on an empty row below them.
fn testWriteNumberedLines(t: *Terminal, n: usize) !void {
    var s = t.vtStream();
    defer s.deinit();
    var buf: [32]u8 = undefined;
    for (0..n) |i| s.nextSlice(try std.mem.print(&buf, "{d}\r\n", .{i}));
}

/// Returns the number written on the row at `row_data` index `idx` by
/// testWriteNumberedLines, or null if the row is empty.
fn testRowNumber(state: *const RenderState, idx: usize) ?usize {
    const cells = state.row_data.items(.cells)[idx].items(.raw);
    var result: ?usize = null;
    for (cells) |cell| {
        const cp = cell.codepoint();
        if (cp < '0' or cp > '9') break;
        result = (result orelse 0) * 10 + (cp - '0');
    }
    return result;
}

test "overscan zero request unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    for ([_]bool{ false, true }) |scrolled| {
        if (scrolled) t.scrollViewport(.{ .delta = -5 });
        try state.update(alloc, &t);
        try testing.expectEqual(10, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(10, state.rowDataRange().end);
        try testing.expect(state.overscan.eql(.{}));
        try testing.expectEqual(0, state.viewportStart());
    }

    // Viewport row 0 is at index 0.
    try testing.expectEqual(36, testRowNumber(&state, 0).?);
}

test "overscan row_data layout" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);

    // Screen rows 0..49 hold "0".."49" and screen row 50 is the empty
    // cursor row. The active area (and bottom viewport) is 41..50.
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 3, .below = 2 };

    // Viewport follows the active area: nothing exists below.
    {
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 0 }));
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(13, state.rowDataRange().end);
        try testing.expectEqual(3, state.viewportStart());
        try testing.expectEqual(-3, state.viewportY(0));
        try testing.expectEqual(0, state.viewportY(3));

        // Viewport row 0 matches a state with no request.
        var plain: RenderState = .empty;
        defer plain.deinit(alloc);
        try plain.update(alloc, &t);
        const vp = state.viewportStart();
        for (0..state.rows) |y| {
            const a = state.row_data.get(vp + y);
            const b = plain.row_data.get(y);
            try testing.expectEqual(b.pin.node, a.pin.node);
            try testing.expectEqual(b.pin.y, a.pin.y);
            try testing.expectEqual(
                @as(page.Row.Backing, @bitCast(b.raw)),
                @as(page.Row.Backing, @bitCast(a.raw)),
            );
            for (b.cells.items(.raw), a.cells.items(.raw)) |bc, ac| {
                try testing.expectEqual(
                    @as(page.Cell.Backing, @bitCast(bc)),
                    @as(page.Cell.Backing, @bitCast(ac)),
                );
            }
        }
        try testing.expectEqual(41, testRowNumber(&state, vp).?);
        try testing.expectEqual(38, testRowNumber(&state, 0).?);
        try testing.expectEqual(40, testRowNumber(&state, vp - 1).?);
    }

    // Scrolled into history: both sides are fully captured.
    {
        t.scrollViewport(.{ .delta = -5 });
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 2 }));
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(15, state.rowDataRange().end);

        const vp = state.viewportStart();
        try testing.expectEqual(36, testRowNumber(&state, vp).?);
        try testing.expectEqual(35, testRowNumber(&state, vp - 1).?);
        try testing.expectEqual(46, testRowNumber(&state, vp + state.rows).?);
        try testing.expectEqual(47, testRowNumber(&state, vp + state.rows + 1).?);
    }

    // At the top of history: nothing exists above.
    {
        t.scrollViewport(.top);
        try state.update(alloc, &t);
        try testing.expectEqual(0, state.overscan.above);
        try testing.expectEqual(2, state.overscan.below);
        try testing.expectEqual(state.viewportStart(), state.rowDataRange().start);
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, testRowNumber(&state, state.viewportStart()).?);

        t.scrollViewport(.{ .row = 1 });
        try state.update(alloc, &t);
        try testing.expectEqual(1, state.overscan.above);
        try testing.expectEqual(2, state.rowDataRange().start);
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, testRowNumber(&state, 2).?);
        try testing.expectEqual(1, testRowNumber(&state, 3).?);
    }

    // Partially scrolled: fewer rows below than requested.
    {
        t.scrollViewport(.bottom);
        t.scrollViewport(.{ .delta = -1 });
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 1 }));
        try testing.expectEqual(14, state.rowDataRange().end);
        try testing.expectEqual(15, state.row_data.len);
    }
}

test "overscan request change forces redraw" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    state.clean();

    // No change is not dirty.
    try state.update(alloc, &t);
    try testing.expectEqual(.false, state.dirty);

    state.overscan_request = .{ .above = 4, .below = 1 };
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);
    try testing.expectEqual(15, state.row_data.len);
    try testing.expectEqual(4, state.viewportStart());
    try testing.expectEqual(41, testRowNumber(&state, 4).?);

    // And back to nothing.
    state.clean();
    state.overscan_request = .{};
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);
    try testing.expectEqual(10, state.row_data.len);
    try testing.expectEqual(41, testRowNumber(&state, 0).?);
}

test "overscan row ids stable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 3, .below = 2 };
    try state.update(alloc, &t);

    // Record all populated ids.
    const range = state.rowDataRange();
    try testing.expectEqual(0, range.start);
    try testing.expectEqual(13, range.end);
    var ids: [13]RenderState.Row.Id = undefined;
    for (&ids, range.start..) |*id, i| id.* = state.row_data.get(i).id();

    // Ids within one update are distinct.
    for (ids, 0..) |a, i| for (ids[i + 1 ..]) |b| {
        try testing.expect(!a.eql(b));
    };

    // Write a line while following the active area. Every row moves up
    // one index and the top row is no longer captured.
    try testWriteNumberedLines(&t, 1);
    try state.update(alloc, &t);
    try testing.expectEqual(13, state.rowDataRange().end);
    for (ids[1..], 0..) |id, i| {
        try testing.expect(id.eql(state.row_data.get(i).id()));
    }

    // Scroll up one row: the recorded ids are back at their original
    // indices, and one more row is captured below.
    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(14, state.rowDataRange().end);
    for (ids, 0..) |id, i| {
        try testing.expect(id.eql(state.row_data.get(i).id()));
    }
}

test "overscan row ids and dirty on in-place rewrite" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Alternate screen has no scrollback, so scrolling a region rewrites
    // rows in place (eraseRowBounded) rather than moving the viewport.
    s.nextSlice("\x1b[?1049h");
    s.nextSlice("0\r\n1\r\n2\r\n3\r\n4");
    s.nextSlice("\x1b[2;5r\x1b[5;2H");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 2, .below = 2 };
    try state.update(alloc, &t);
    try testing.expect(state.overscan.eql(.{}));

    const vp = state.viewportStart();
    var ids: [5]RenderState.Row.Id = undefined;
    var nums: [5]?usize = undefined;
    for (&ids, &nums, vp..) |*id, *num, i| {
        id.* = state.row_data.get(i).id();
        num.* = testRowNumber(&state, i);
    }
    state.clean();

    // Scroll the region up one row.
    s.nextSlice("\r\n5");
    try state.update(alloc, &t);
    try testing.expect(state.dirty != .false);

    // The id contract: a row with an unchanged id and no dirty mark has
    // unchanged content, and every row whose content changed is dirty.
    for (ids, nums, vp..) |id, num, i| {
        const row = state.row_data.get(i);
        const new_num = testRowNumber(&state, i);
        try testing.expectEqual(if (i == vp) 0 else i - vp + 1, new_num.?);
        if (id.eql(row.id()) and !row.dirty) {
            try testing.expectEqual(num, new_num);
        }
        if (num != new_num) try testing.expect(row.dirty);
    }

    // At the time of writing, rotating rows in place invalidates the
    // page serial (PageList.invalidateNodeLayout), so no id survives.
    for (ids, vp..) |id, i| {
        try testing.expect(!id.eql(state.row_data.get(i).id()));
    }
}

test "overscan cursor in overscan row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);

    // The cursor is on the last active row.
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .below = 2 };

    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.below);
    try testing.expect(state.cursor.viewport == null);

    t.scrollViewport(.bottom);
    try state.update(alloc, &t);
    try testing.expectEqual(state.rows - 1, state.cursor.viewport.?.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
}

test "overscan selection on overscan rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);

    // Select the last two active rows.
    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 8 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 9 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .below = 2 };

    // Scroll so the last active row is overscan-below.
    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.below);

    const vp = state.viewportStart();
    const sels = state.row_data.items(.selection);
    try testing.expectEqual(
        [2]size.CellCountInt{ 0, 9 },
        sels[vp + state.rows - 1].?,
    );
    try testing.expectEqual(
        [2]size.CellCountInt{ 0, 2 },
        sels[vp + state.rows].?,
    );
    try testing.expect(sels[vp + state.rows - 2] == null);
}

test "placeholders: runs" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Run = struct {
        y: usize = 0,
        x: size.CellCountInt,
        width: size.CellCountInt,
        image_id: u32 = 0,
        placement_id: u32 = 0,
        row: u32 = 0,
        col: u32 = 0,
    };

    // Each case writes `input` to a new terminal and expects exactly
    // these placeholder runs, in order. No images exist, so none of them
    // have anything to draw.
    const cases: []const struct {
        input: []const u8,
        runs: []const Run,
    } = &.{
        // No placeholders.
        .{ .input = "hello\r\nworld\r\n1\r\n2", .runs = &.{} },

        // A single cell.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}",
            .runs = &.{.{ .x = 0, .width = 1 }},
        },

        // Two runs because the column jumps.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030E}",
            .runs = &.{
                .{ .x = 0, .width = 1 },
                .{ .x = 1, .width = 1, .col = 2 },
            },
        },

        // Explicit rows and columns that continue the run.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}" ++
                "\u{10EEEE}\u{0305}\u{030E}",
            .runs = &.{.{ .x = 0, .width = 3 }},
        },

        // Cells without a column continue the run.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{10EEEE}\u{0305}",
            .runs = &.{.{ .x = 0, .width = 3 }},
        },

        // Plain cells with no style or grapheme.
        .{
            .input = "\u{10EEEE}\u{10EEEE}\u{10EEEE}",
            .runs = &.{.{ .x = 0, .width = 3 }},
        },

        // Styled plain cells, which are found through their style run.
        .{
            .input = "\x1b[38;5;42mA\u{10EEEE}\u{0305}\u{030D}\u{10EEEE}" ++
                "\u{10EEEE}B\u{10EEEE}\u{10EEEE}",
            .runs = &.{
                .{ .x = 1, .width = 3, .image_id = 42, .col = 1 },
                .{ .x = 5, .width = 2, .image_id = 42 },
            },
        },

        // A run ends at a cell that isn't a placeholder.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}ABC",
            .runs = &.{.{ .x = 0, .width = 2 }},
        },

        // A run starting in the middle of the row.
        .{
            .input = "ABC\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}",
            .runs = &.{.{ .x = 3, .width = 2 }},
        },

        // The image ID as a palette foreground color.
        .{
            .input = "\x1b[38;5;42m\u{10EEEE}\u{0305}\u{0305}",
            .runs = &.{.{ .x = 0, .width = 1, .image_id = 42 }},
        },

        // The third diacritic sets the high 8 bits of the image ID. A
        // cell without it continues the run, and a different one breaks
        // it.
        .{
            .input = "\x1b[38;5;42m\u{10EEEE}\u{0305}\u{0305}\u{030E}" ++
                "\u{10EEEE}\u{0305}\u{10EEEE}\u{0305}\u{030E}\u{0305}",
            .runs = &.{
                .{ .x = 0, .width = 2, .image_id = 42 | (2 << 24) },
                .{ .x = 2, .width = 1, .image_id = 42, .col = 2 },
            },
        },

        // The placement ID as the underline color. A different placement
        // ID breaks the run.
        .{
            .input = "\x1b[38;5;42m\x1b[58;5;21m\u{10EEEE}\u{0305}\u{0305}" ++
                "\u{10EEEE}\x1b[58;5;22m\u{10EEEE}",
            .runs = &.{
                .{ .x = 0, .width = 2, .image_id = 42, .placement_id = 21 },
                .{ .x = 2, .width = 1, .image_id = 42, .placement_id = 22 },
            },
        },

        // RGB colors for both IDs, across several rows.
        .{
            .input = "\x1b[38;2;1;2;3m\x1b[58;2;0;0;7m" ++
                "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\r\nx\r\n" ++
                "\u{10EEEE}\u{030D}\u{0305}\u{10EEEE}\u{10EEEE}",
            .runs = &.{
                .{ .y = 0, .x = 0, .width = 2, .image_id = 0x010203, .placement_id = 7 },
                .{ .y = 2, .x = 0, .width = 3, .image_id = 0x010203, .placement_id = 7, .row = 1 },
            },
        },
    };

    for (cases) |case| {
        var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
        defer t.deinit(alloc);
        t.modes.set(.grapheme_cluster, true);
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(case.input);

        var state: RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var actual: std.ArrayList(Run) = .empty;
        defer actual.deinit(alloc);
        for (state.row_data.items(.placeholders), 0..) |runs, y| {
            for (runs.items) |run| try actual.append(alloc, .{
                .y = y,
                .x = run.x,
                .width = run.width,
                .image_id = run.image_id,
                .placement_id = run.placement_id,
                .row = run.row,
                .col = run.col,
            });
        }
        try testing.expectEqualSlices(Run, case.runs, actual.items);

        var it = state.imagePlacementIterator();
        try testing.expect(it.next() == null);
    }
}

test "placeholders: resolved virtual placements" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
        .columns = 2,
        .rows = 2,
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    t.screens.active.cursorAbsolute(3, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}");
    t.screens.active.cursorAbsolute(3, 2);
    try t.printString("\u{10EEEE}\u{030D}\u{0305}\u{10EEEE}");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Each run draws half of the image, like the renderer would.
    var it = state.imagePlacementIterator();
    for (0..2) |y| {
        const p = it.next().?;
        try testing.expectEqual(RenderState.KittyPlacement.Kind.virtual, p.protocol.kitty.kind);
        try testing.expectEqual(1, p.image_id);
        try testing.expectEqual(1, p.protocol.kitty.placement_id);
        try testing.expectEqual(3, p.x);
        try testing.expectEqual(@as(i32, @intCast(y + 1)), p.y);
        try testing.expectEqual(2, p.cols);
        try testing.expectEqual(1, p.rows);
        try testing.expectEqual(20, p.width);
        try testing.expectEqual(10, p.height);
        try testing.expectEqual(0, p.source_x);
        try testing.expectEqual(@as(u32, @intCast(y * 5)), p.source_y);
        try testing.expectEqual(10, p.source_width);
        try testing.expectEqual(5, p.source_height);
        try testing.expectEqual(-1, p.z);
        try testing.expectEqual(RenderState.ImageLayer.below_text, p.layer);
        try testing.expectEqual(RenderState.ImageProtocol.kitty, std.meta.activeTag(p.protocol));
        try testing.expectEqual(
            t.screens.active.kitty_images.imageById(1).?.generation,
            p.image_generation,
        );
    }
    try testing.expect(it.next() == null);
}

test "placeholders: only dirty rows are resolved again" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
        .columns = 2,
        .rows = 2,
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\r\n");
    try t.printString("\u{10EEEE}\u{030D}\u{0305}\u{10EEEE}");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Overwrite the geometry with a marker value, so we can tell when a
    // run is looked up again.
    const poison = 12345;
    const rows = state.row_data.items(.placeholders);
    for (rows[0..2]) |runs| {
        try testing.expectEqual(1, runs.items.len);
        try testing.expectEqual(RenderState.Placeholder.State.visible, runs.items[0].state);
        runs.items[0].geometry.width = poison;
    }

    // An update with no changes looks up nothing.
    try state.update(alloc, &t);
    try testing.expectEqual(poison, rows[0].items[0].geometry.width);
    try testing.expectEqual(poison, rows[1].items[0].geometry.width);

    // Only the dirty row is rebuilt and looked up again.
    t.screens.active.pages.pin(.{ .active = .{ .y = 1 } }).?.markDirty();
    try state.update(alloc, &t);
    try testing.expectEqual(poison, rows[0].items[0].geometry.width);
    try testing.expectEqual(20, rows[1].items[0].geometry.width);

    // A change to the image storage looks up every row again.
    t.screens.active.kitty_images.markMutated(io);
    try state.update(alloc, &t);
    try testing.expectEqual(20, rows[0].items[0].geometry.width);

    // So does a cell size change. With wider cells, the image is
    // centered in the placement grid.
    rows[0].items[0].geometry.width = poison;
    t.width_px = 200;
    try state.update(alloc, &t);
    try testing.expectEqual(20, rows[0].items[0].geometry.width);
    try testing.expectEqual(10, rows[0].items[0].geometry.offset_x);
}

test "placeholders: relative placement rooted at a virtual placement" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
        .columns = 2,
        .rows = 2,
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });

    // Placeholder cells at (3, 1) and (1, 2). Relative placements
    // attached to the virtual placement are positioned from the smallest
    // column and row, (1, 1), even though no cell is there.
    t.screens.active.cursorAbsolute(3, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    t.screens.active.cursorAbsolute(1, 2);
    try t.printString("\u{10EEEE}\u{030D}\u{0305}");

    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 1,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 5,
    });

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var it = state.imagePlacementIterator();
    try testing.expectEqual(.virtual, it.next().?.protocol.kitty.kind);
    try testing.expectEqual(.virtual, it.next().?.protocol.kitty.kind);
    const child = it.next().?;
    try testing.expectEqual(RenderState.KittyPlacement.Kind.relative, child.protocol.kitty.kind);
    try testing.expectEqual(1, child.image_id);
    try testing.expectEqual(2, child.protocol.kitty.placement_id);
    try testing.expectEqual(RenderState.ImageLayer.above_text, child.layer);
    try testing.expectEqual(2, child.x);
    try testing.expectEqual(3, child.y);
    try testing.expectEqual(1, child.cols);
    try testing.expectEqual(1, child.rows);
    try testing.expectEqual(10, child.width);
    try testing.expectEqual(10, child.height);
    try testing.expectEqual(5, child.z);
    try testing.expect(it.next() == null);

    // A new placeholder cell further left moves the child, even
    // though the storage didn't change.
    t.screens.active.cursorAbsolute(0, 3);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try state.update(alloc, &t);
    it = state.imagePlacementIterator();
    for (0..3) |_| try testing.expectEqual(.virtual, it.next().?.protocol.kitty.kind);
    const moved = it.next().?;
    try testing.expectEqual(1, moved.x);
    try testing.expectEqual(3, moved.y);
    try testing.expect(it.next() == null);

    // Without placeholder cells in the viewport the child isn't drawn.
    t.eraseDisplay(.complete, false);
    try state.update(alloc, &t);
    it = state.imagePlacementIterator();
    try testing.expect(it.next() == null);
}

/// Adds a complete 1 by 1 pixel Kitty image with the given ID to the
/// active screen, for the `fixed:` tests.
fn testFixedImage(t: *Terminal, image_id: u32) !void {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const pixels = try alloc.alloc(u8, 3);
    @memset(pixels, 0);
    try t.screens.active.kitty_images.addImage(io, alloc, t.screens.active, .{
        .id = image_id,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
}

/// Adds a fixed Kitty placement of image 1 at a cell of the active area,
/// for the `fixed:` tests.
fn testFixedPlacement(
    t: *Terminal,
    placement_id: u32,
    x: size.CellCountInt,
    y: size.CellCountInt,
    columns: u32,
    rows: u32,
) !void {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const s = t.screens.active;
    const pin = try s.pages.trackPin(
        s.pages.pin(.{ .active = .{ .x = x, .y = y } }).?,
    );
    try s.kitty_images.addPlacement(io, alloc, s, 1, placement_id, .{
        .location = .{ .pin = pin },
        .columns = columns,
        .rows = rows,
    });
}

/// Returns the only image placement of a render state, failing the test
/// if there isn't exactly one.
fn testOnlyPlacement(state: *const RenderState) !RenderState.ImagePlacement {
    var it = state.imagePlacementIterator();
    const p = it.next() orelse return error.TestExpectedPlacement;
    if (it.next() != null) return error.TestUnexpectedPlacement;
    return p;
}

test "fixed: pin placement in viewport" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 10, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    const storage = &t.screens.active.kitty_images;
    try testFixedImage(&t, 1);
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 7, .{
        .location = .{ .pin = pin },
        .columns = 3,
        .rows = 2,
        .x_offset = 4,
        .y_offset = 3,
        .z = -5,
    });

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const p = try testOnlyPlacement(&state);
    const image = storage.imageById(1).?;
    const sp = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 7 },
    }).?;
    const grid = sp.gridSize(image, &t);
    const dest = sp.pixelSize(image, &t);
    const offset = sp.cellOffset(&t);
    const source = sp.sourceRect(image);
    try testing.expectEqual(RenderState.KittyPlacement.Kind.fixed, p.protocol.kitty.kind);
    try testing.expectEqual(7, p.protocol.kitty.placement_id);
    try testing.expectEqual(1, p.image_id);
    try testing.expectEqual(image.generation, p.image_generation);
    try testing.expectEqual(2, p.x);
    try testing.expectEqual(1, p.y);
    try testing.expectEqual(3, p.cols);
    try testing.expectEqual(2, p.rows);
    try testing.expectEqual(grid.cols, p.cols);
    try testing.expectEqual(grid.rows, p.rows);
    try testing.expectEqual(4, p.offset_x);
    try testing.expectEqual(3, p.offset_y);
    try testing.expectEqual(offset.x, p.offset_x);
    try testing.expectEqual(offset.y, p.offset_y);
    try testing.expectEqual(dest.width, p.width);
    try testing.expectEqual(dest.height, p.height);
    try testing.expectEqual(source.x, p.source_x);
    try testing.expectEqual(source.y, p.source_y);
    try testing.expectEqual(source.width, p.source_width);
    try testing.expectEqual(source.height, p.source_height);
    try testing.expectEqual(-5, p.z);
    try testing.expectEqual(RenderState.ImageLayer.below_text, p.layer);
}

test "fixed: scrolled partially above the viewport" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 1, 0, 2, 3);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 1 };
    try state.update(alloc, &t);
    {
        const p = try testOnlyPlacement(&state);
        try testing.expectEqual(1, p.x);
        try testing.expectEqual(0, p.y);
    }

    // Two lines of output move the placement two rows up. Its top row is
    // now above the one overscan row, and it is still reported whole.
    t.setCursorPos(5, 1);
    try t.index();
    try t.index();
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.above);
    {
        const p = try testOnlyPlacement(&state);
        try testing.expectEqual(1, p.x);
        try testing.expectEqual(-2, p.y);
        try testing.expectEqual(2, p.cols);
        try testing.expectEqual(3, p.rows);
        try testing.expectEqual(20, p.width);
        try testing.expectEqual(30, p.height);
    }

    // Scrolling the viewport up a row moves it back down.
    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    {
        const p = try testOnlyPlacement(&state);
        try testing.expectEqual(-1, p.y);
        try testing.expectEqual(30, p.height);
    }

    // Three lines up, only the overscan row shows it.
    t.scrollViewport(.bottom);
    try t.index();
    try state.update(alloc, &t);
    try testing.expectEqual(-3, (try testOnlyPlacement(&state)).y);

    // Four lines up, it doesn't reach the captured rows.
    try t.index();
    try state.update(alloc, &t);
    var it = state.imagePlacementIterator();
    try testing.expect(it.next() == null);
}

test "fixed: pin on a page above the captured rows" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    const pages = &t.screens.active.pages;
    const first = pages.pages.first.?;
    const page_rows: usize = first.capacity().rows;

    // Scroll the first row far enough that the viewport is on the next
    // page. The first row is then `distance` rows above the viewport.
    try testFixedImage(&t, 1);
    const distance = page_rows + 6;
    t.setCursorPos(5, 1);
    for (0..distance) |_| try t.index();
    try testing.expect(pages.getTopLeft(.viewport).node == first.next.?);

    // Placements on the first row: one tall enough to reach the second
    // row of the viewport, and one that ends just above the viewport.
    {
        const s = t.screens.active;
        const top: PageList.Pin = .{ .node = first, .y = 0, .x = 1 };
        try s.kitty_images.addPlacement(io, alloc, s, 1, 1, .{
            .location = .{ .pin = try pages.trackPin(top) },
            .columns = 1,
            .rows = @intCast(distance + 2),
        });
        try s.kitty_images.addPlacement(io, alloc, s, 1, 2, .{
            .location = .{ .pin = try pages.trackPin(top) },
            .columns = 1,
            .rows = @intCast(distance),
        });
    }

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // The viewport is one chunk on the second page, so the first page is
    // only found by the walk up.
    try testing.expectEqual(1, state.kitty.chunks.items.len);
    try testing.expect(state.kitty.chunks.items[0].node != first);

    const p = try testOnlyPlacement(&state);
    try testing.expectEqual(1, p.protocol.kitty.placement_id);
    try testing.expectEqual(1, p.x);
    try testing.expectEqual(-@as(i32, @intCast(distance)), p.y);
    try testing.expectEqual(@as(u32, @intCast(distance + 2)), p.rows);
}

test "fixed: rowIndexOfPin walks pages above and below" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    const pages = &t.screens.active.pages;
    const first = pages.pages.first.?;
    const page_rows: isize = first.capacity().rows;

    // Three pages, with the viewport on the middle one, three rows down.
    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 0, 0, 1, 1);
    t.setCursorPos(5, 1);
    for (0..@intCast(2 * page_rows + 10)) |_| try t.index();
    const middle = first.next.?;
    const last = middle.next.?;
    t.scrollViewport(.top);
    t.scrollViewport(.{ .delta = @intCast(page_rows + 3) });
    try testing.expect(pages.getTopLeft(.viewport).node == middle);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const chunks = state.kitty.chunks.items;
    try testing.expectEqual(1, chunks.len);
    try testing.expectEqual(middle, chunks[0].node);
    try testing.expectEqual(0, chunks[0].index);
    try testing.expectEqual(3, chunks[0].start);
    const captured: isize = 5;

    // On a captured page, including its rows outside the captured rows.
    try testing.expectEqual(0, Kitty.rowIndexOfPin(chunks, .{ .node = middle, .y = 3 }, captured, 1, 0));
    try testing.expectEqual(-3, Kitty.rowIndexOfPin(chunks, .{ .node = middle, .y = 0 }, captured, 1, 0));
    try testing.expectEqual(7, Kitty.rowIndexOfPin(chunks, .{ .node = middle, .y = 10 }, captured, 1, 0));

    // Above: the last row of the first page is index -4. It is found when
    // the placement can reach index 0, through its height or a positive
    // offset, and not otherwise.
    const above: PageList.Pin = .{ .node = first, .y = @intCast(page_rows - 1) };
    try testing.expectEqual(-4, Kitty.rowIndexOfPin(chunks, above, captured, 5, 0));
    try testing.expectEqual(-4, Kitty.rowIndexOfPin(chunks, above, captured, 1, 4));
    try testing.expectEqual(null, Kitty.rowIndexOfPin(chunks, above, captured, 4, 0));
    try testing.expectEqual(null, Kitty.rowIndexOfPin(chunks, above, captured, 4, -2));
    const first_top: PageList.Pin = .{ .node = first, .y = 0 };
    try testing.expectEqual(-3 - page_rows, Kitty.rowIndexOfPin(chunks, first_top, captured, @intCast(page_rows + 4), 0));

    // Below: the first row of the last page comes right after the middle
    // page's rows. Only a negative offset that moves it up into the
    // captured rows finds it.
    const below_index: isize = -3 + @as(isize, middle.rows());
    const below: PageList.Pin = .{ .node = last, .y = 0 };
    try testing.expectEqual(null, Kitty.rowIndexOfPin(chunks, below, captured, 100, 0));
    try testing.expectEqual(below_index, Kitty.rowIndexOfPin(chunks, below, captured, 1, @intCast(captured - 1 - below_index)));
    try testing.expectEqual(null, Kitty.rowIndexOfPin(chunks, below, captured, 1, @intCast(captured - below_index)));
    const below2: PageList.Pin = .{ .node = last, .y = 2 };
    try testing.expectEqual(below_index + 2, Kitty.rowIndexOfPin(chunks, below2, captured, 1, @intCast(-(below_index + 2))));
}

test "fixed: region scroll moves the placement without a generation change" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 6, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    try t.switchScreenMode(.@"1049", true);

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 2, 3, 1, 1);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(3, (try testOnlyPlacement(&state)).y);

    // Mark the template so we can tell whether the roots are rebuilt.
    const poison = 12345;
    state.kitty.roots.items[0].placement.width = poison;

    // Scroll rows 2 to 5 (1-based) up by one with an index at the bottom
    // margin.
    const storage = &t.screens.active.kitty_images;
    const generation = storage.generation;
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);
    try t.index();
    try testing.expectEqual(generation, storage.generation);
    try state.update(alloc, &t);
    {
        const p = try testOnlyPlacement(&state);
        try testing.expectEqual(2, p.x);
        try testing.expectEqual(2, p.y);
        try testing.expectEqual(poison, p.width);
    }

    // A storage change rebuilds the roots.
    storage.markMutated(io);
    try state.update(alloc, &t);
    try testing.expectEqual(10, (try testOnlyPlacement(&state)).width);
}

test "fixed: viewport scroll does not rebuild roots" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 0, 2, 1, 2);
    t.setCursorPos(5, 1);
    for (0..3) |_| try t.index();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(-1, (try testOnlyPlacement(&state)).y);
    const poison = 12345;
    state.kitty.roots.items[0].placement.width = poison;

    t.scrollViewport(.{ .delta = -2 });
    try state.update(alloc, &t);
    const p = try testOnlyPlacement(&state);
    try testing.expectEqual(1, p.y);
    try testing.expectEqual(poison, p.width);
}

test "fixed: dirty row with only fixed placements skips the slow path" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 0, 1, 1, 1);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const poison = 12345;
    state.kitty.placed.items[0].width = poison;

    // Clear the dirty flags so we can see that the row was rebuilt.
    @memset(state.row_data.items(.dirty), false);
    t.screens.active.pages.pin(.{ .active = .{ .y = 3 } }).?.markDirty();
    try state.update(alloc, &t);
    try testing.expect(state.row_data.items(.dirty)[3]);
    try testing.expectEqual(poison, (try testOnlyPlacement(&state)).width);
}

test "fixed: garbage pin is skipped" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;

    // A placement on the first page, scrolled onto the second page's
    // history, and tall enough to reach the viewport.
    const pages = &t.screens.active.pages;
    const page_rows: usize = pages.pages.first.?.capacity().rows;
    const distance = page_rows + 6;
    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 0, 0, 1, @intCast(distance + 2));
    t.setCursorPos(5, 1);
    for (0..distance) |_| try t.index();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(
        -@as(i32, @intCast(distance)),
        (try testOnlyPlacement(&state)).y,
    );

    // Lowering the scrollback limit prunes the first page. The pin moves
    // to the top of the next page, where it would still reach the
    // viewport, and becomes garbage. The storage keeps the placement and
    // its generation until it reaps garbage.
    const storage = &t.screens.active.kitty_images;
    const generation = storage.generation;
    t.setScrollbackMaxLines(1);
    try testing.expectEqual(generation, storage.generation);
    try testing.expectEqual(1, storage.placements.count());
    var storage_it = storage.placements.valueIterator();
    try testing.expect(storage_it.next().?.location.pin.garbage);
    try state.update(alloc, &t);
    var it = state.imagePlacementIterator();
    try testing.expect(it.next() == null);
}

test "fixed: screen switch rebuilds roots" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 3, 2, 1, 1);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(3, (try testOnlyPlacement(&state)).x);

    try t.switchScreenMode(.@"1049", true);
    try state.update(alloc, &t);
    var it = state.imagePlacementIterator();
    try testing.expect(it.next() == null);

    try t.switchScreenMode(.@"1049", false);
    try state.update(alloc, &t);
    const p = try testOnlyPlacement(&state);
    try testing.expectEqual(3, p.x);
    try testing.expectEqual(2, p.y);
}

/// Adds a Kitty placement of image 1 relative to another placement of
/// image 1, for the `fixed: relative` tests.
fn testRelativePlacement(
    t: *Terminal,
    placement_id: u32,
    parent_id: u32,
    horizontal_offset: i32,
    vertical_offset: i32,
    columns: u32,
    rows: u32,
) !void {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const s = t.screens.active;
    try s.kitty_images.addPlacement(io, alloc, s, 1, placement_id, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = parent_id },
            },
            .horizontal_offset = horizontal_offset,
            .vertical_offset = vertical_offset,
        } },
        .columns = columns,
        .rows = rows,
    });
}

/// Returns the image placement of a render state with the given
/// placement ID, failing the test if there isn't exactly one.
fn testPlacementById(
    state: *const RenderState,
    placement_id: u32,
) !RenderState.ImagePlacement {
    var result: ?RenderState.ImagePlacement = null;
    var it = state.imagePlacementIterator();
    while (it.next()) |p| {
        if (p.protocol.kitty.placement_id != placement_id) continue;
        if (result != null) return error.TestUnexpectedPlacement;
        result = p;
    }
    return result orelse error.TestExpectedPlacement;
}

test "fixed: relative child at parent plus positive offsets" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{ .rows = 10, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 2, 1, 1, 1);
    try testRelativePlacement(&t, 2, 1, 3, 2, 2, 3);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const parent = try testPlacementById(&state, 1);
    try testing.expectEqual(RenderState.KittyPlacement.Kind.fixed, parent.protocol.kitty.kind);
    try testing.expectEqual(2, parent.x);
    try testing.expectEqual(1, parent.y);

    const child = try testPlacementById(&state, 2);
    try testing.expectEqual(RenderState.KittyPlacement.Kind.relative, child.protocol.kitty.kind);
    try testing.expectEqual(1, child.image_id);
    try testing.expectEqual(5, child.x);
    try testing.expectEqual(3, child.y);
    try testing.expectEqual(2, child.cols);
    try testing.expectEqual(3, child.rows);
    try testing.expectEqual(20, child.width);
    try testing.expectEqual(30, child.height);
}

test "fixed: relative child with negative offsets" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{ .rows = 10, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    // The child hangs above and left of its parent at the top-left
    // corner. It is reported whole even though its top-left cell is
    // outside the screen.
    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 0, 0, 1, 1);
    try testRelativePlacement(&t, 2, 1, -1, -1, 2, 2);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const child = try testPlacementById(&state, 2);
    try testing.expectEqual(RenderState.KittyPlacement.Kind.relative, child.protocol.kitty.kind);
    try testing.expectEqual(-1, child.x);
    try testing.expectEqual(-1, child.y);
    try testing.expectEqual(2, child.cols);
    try testing.expectEqual(2, child.rows);
}

test "fixed: relative chain two levels deep" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{ .rows = 10, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 1, 1, 1, 1);
    try testRelativePlacement(&t, 2, 1, 1, 1, 1, 1);
    try testRelativePlacement(&t, 3, 2, 2, 1, 1, 1);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const child = try testPlacementById(&state, 2);
    try testing.expectEqual(2, child.x);
    try testing.expectEqual(2, child.y);
    const grandchild = try testPlacementById(&state, 3);
    try testing.expectEqual(RenderState.KittyPlacement.Kind.relative, grandchild.protocol.kitty.kind);
    try testing.expectEqual(4, grandchild.x);
    try testing.expectEqual(3, grandchild.y);
}

test "fixed: relative to a parent above the captured rows" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    const pages = &t.screens.active.pages;
    const first = pages.pages.first.?;
    const page_rows: usize = first.capacity().rows;

    // The parent is on the first row, and the child is far enough below
    // it to be on the second row of the viewport once the parent scrolls
    // onto an earlier page.
    const distance = page_rows + 6;
    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 1, 0, 1, 1);
    try testRelativePlacement(&t, 2, 1, 2, @intCast(distance + 1), 1, 1);
    t.setCursorPos(5, 1);
    for (0..distance) |_| try t.index();
    try testing.expect(pages.getTopLeft(.viewport).node == first.next.?);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Only the child is in the captured rows. The parent's page is only
    // found by the walk up.
    try testing.expectEqual(1, state.kitty.chunks.items.len);
    try testing.expect(state.kitty.chunks.items[0].node != first);
    const p = try testOnlyPlacement(&state);
    try testing.expectEqual(RenderState.KittyPlacement.Kind.relative, p.protocol.kitty.kind);
    try testing.expectEqual(2, p.protocol.kitty.placement_id);
    try testing.expectEqual(3, p.x);
    try testing.expectEqual(1, p.y);
}

test "fixed: relative to a parent below the captured rows" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    const pages = &t.screens.active.pages;
    const first = pages.pages.first.?;
    const page_rows: usize = first.capacity().rows;

    // Enough output that the active area is on a later page than the top
    // of the scrollback, where the viewport goes.
    t.setCursorPos(5, 1);
    for (0..page_rows + 10) |_| try t.index();
    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 1, 0, 1, 1);
    const parent_pin = pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?;
    try testing.expect(parent_pin.node != first);
    const parent_y: i32 = @intCast(pages.pointFromPin(.screen, parent_pin).?.screen.y);

    // The child moves up from the parent to the second row of the top of
    // the scrollback.
    try testRelativePlacement(&t, 2, 1, 1, 1 - parent_y, 1, 1);
    t.scrollViewport(.top);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    try testing.expectEqual(1, state.kitty.chunks.items.len);
    try testing.expectEqual(first, state.kitty.chunks.items[0].node);
    const p = try testOnlyPlacement(&state);
    try testing.expectEqual(RenderState.KittyPlacement.Kind.relative, p.protocol.kitty.kind);
    try testing.expectEqual(2, p.x);
    try testing.expectEqual(1, p.y);
}

test "fixed: relative with a broken chain is not drawn" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;

    // Placement 99 doesn't exist.
    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 1, 1, 1, 1);
    try testRelativePlacement(&t, 2, 99, 1, 1, 1, 1);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const p = try testOnlyPlacement(&state);
    try testing.expectEqual(1, p.protocol.kitty.placement_id);
    try testing.expectEqual(1, state.kitty.roots.items.len);
}

test "fixed: relative to a parent with a garbage pin is not drawn" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;

    // The parent is on the first page, scrolled onto the second page's
    // history. The child is far enough below it to be in the viewport.
    const pages = &t.screens.active.pages;
    const page_rows: usize = pages.pages.first.?.capacity().rows;
    const distance = page_rows + 6;
    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 0, 0, 1, 1);
    try testRelativePlacement(&t, 2, 1, 0, @intCast(distance + 1), 1, 1);
    t.setCursorPos(5, 1);
    for (0..distance) |_| try t.index();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(2, (try testOnlyPlacement(&state)).protocol.kitty.placement_id);

    // Pruning the first page makes the parent's pin garbage without a
    // generation change.
    const storage = &t.screens.active.kitty_images;
    const generation = storage.generation;
    t.setScrollbackMaxLines(1);
    try testing.expectEqual(generation, storage.generation);
    try testing.expect(storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?.location.pin.garbage);
    try state.update(alloc, &t);
    var it = state.imagePlacementIterator();
    try testing.expect(it.next() == null);
}

test "fixed: relative moves with its parent on a region scroll" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{ .rows = 6, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    try t.switchScreenMode(.@"1049", true);

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 2, 3, 1, 1);
    try testRelativePlacement(&t, 2, 1, 1, 1, 1, 1);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(3, (try testPlacementById(&state, 1)).y);
    try testing.expectEqual(4, (try testPlacementById(&state, 2)).y);
    const placements_generation = state.imagePlacementsGeneration();

    // Scroll rows 2 to 5 (1-based) up by one. Both move up a row, and
    // the storage generation stays the same.
    const storage = &t.screens.active.kitty_images;
    const generation = storage.generation;
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);
    try t.index();
    try testing.expectEqual(generation, storage.generation);
    try state.update(alloc, &t);
    {
        const parent = try testPlacementById(&state, 1);
        try testing.expectEqual(2, parent.x);
        try testing.expectEqual(2, parent.y);
        const child = try testPlacementById(&state, 2);
        try testing.expectEqual(3, child.x);
        try testing.expectEqual(3, child.y);
    }
    try testing.expect(state.imagePlacementsGeneration() != placements_generation);
}

test "placeholders: relative rooted at a virtual placement in an overscan row" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    const storage = &t.screens.active.kitty_images;
    try testFixedImage(&t, 1);
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
        .columns = 1,
        .rows = 1,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 1,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
    });

    // A placeholder cell at (3, 0), then one line of output to move it
    // into the overscan row above the viewport.
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    t.screens.active.cursorAbsolute(3, 0);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.setAttribute(.{ .unset = {} });
    t.setCursorPos(5, 1);
    try t.index();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 1 };
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.above);

    var it = state.imagePlacementIterator();
    const parent = it.next().?;
    try testing.expectEqual(RenderState.KittyPlacement.Kind.virtual, parent.protocol.kitty.kind);
    try testing.expectEqual(-1, parent.y);
    const child = it.next().?;
    try testing.expectEqual(RenderState.KittyPlacement.Kind.relative, child.protocol.kitty.kind);
    try testing.expectEqual(4, child.x);
    try testing.expectEqual(1, child.y);
    try testing.expect(it.next() == null);
}

/// Sets up image 1 with a fixed placement (ID 1) at (0, 4) and a virtual
/// placement (ID 2) with one placeholder run at (3, 1), on a 5x10
/// terminal.
fn testImagesGenerationScene(t: *Terminal) !void {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    t.width_px = 100;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    try testFixedImage(t, 1);
    try testFixedPlacement(t, 1, 0, 4, 1, 1);
    try t.screens.active.kitty_images.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .virtual = {} },
        .columns = 1,
        .rows = 1,
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 2 });
    t.screens.active.cursorAbsolute(3, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.setAttribute(.{ .unset = {} });
}

/// Returns the number of placements the iterator returns.
fn testPlacementCount(state: *const RenderState) usize {
    var it = state.imagePlacementIterator();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

test "placements_generation: zero without images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    try t.printString("hello");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.imagePlacementsGeneration());
    try t.printString("world");
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.imagePlacementsGeneration());
}

test "placements_generation: stable on a quiet update" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    try testImagesGenerationScene(&t);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(2, testPlacementCount(&state));
    const generation = state.imagePlacementsGeneration();
    try testing.expect(generation != 0);

    try state.update(alloc, &t);
    try testing.expectEqual(generation, state.imagePlacementsGeneration());
}

test "placements_generation: stable across a dirty row with only fixed placements" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 0, 1, 1, 1);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const generation = state.imagePlacementsGeneration();

    // The slow path would build `placed` again and drop the marker.
    const poison = 12345;
    state.kitty.placed.items[0].width = poison;

    t.screens.active.pages.pin(.{ .active = .{ .y = 3 } }).?.markDirty();
    try state.update(alloc, &t);
    try testing.expectEqual(generation, state.imagePlacementsGeneration());
    try testing.expectEqual(poison, (try testOnlyPlacement(&state)).width);
}

test "placements_generation: stable across a dirty row that has no placeholders while virtual runs exist elsewhere" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    try testImagesGenerationScene(&t);

    // A child of the virtual placement, so that a dirty row builds
    // `placed` again and the comparison with the previous one decides.
    try t.screens.active.kitty_images.addPlacement(io, alloc, t.screens.active, 1, 3, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 2 },
            },
            .horizontal_offset = 1,
            .vertical_offset = 1,
        } },
        .columns = 1,
        .rows = 1,
    });

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(3, testPlacementCount(&state));
    try testing.expect(state.kitty.virtual_anchors > 0);
    const generation = state.imagePlacementsGeneration();

    // Mark the row dirty directly. Moving the cursor would also rebuild
    // the placeholder row the cursor leaves.
    @memset(state.row_data.items(.dirty), false);
    t.screens.active.pages.pin(.{ .active = .{ .y = 3 } }).?.markDirty();
    try state.update(alloc, &t);
    try testing.expect(state.row_data.items(.dirty)[3]);
    try testing.expect(!state.row_data.items(.dirty)[1]);
    try testing.expectEqual(generation, state.imagePlacementsGeneration());
    try testing.expectEqual(3, testPlacementCount(&state));
}

test "placements_generation: changes when a placeholder row is overwritten with text" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    try testImagesGenerationScene(&t);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(2, testPlacementCount(&state));
    const generation = state.imagePlacementsGeneration();

    t.screens.active.cursorAbsolute(3, 1);
    try t.printString("x");
    try state.update(alloc, &t);
    try testing.expect(generation != state.imagePlacementsGeneration());

    // Only the fixed placement is left.
    const p = try testOnlyPlacement(&state);
    try testing.expectEqual(RenderState.KittyPlacement.Kind.fixed, p.protocol.kitty.kind);
}

test "placements_generation: changes when a placeholder run is added" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    try testImagesGenerationScene(&t);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const generation = state.imagePlacementsGeneration();

    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 2 });
    t.screens.active.cursorAbsolute(5, 2);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try state.update(alloc, &t);
    try testing.expect(generation != state.imagePlacementsGeneration());
    try testing.expectEqual(3, testPlacementCount(&state));
}

test "placements_generation: changes on viewport scroll with a fixed placement" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .rows = 5,
        .cols = 10,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 0, 2, 1, 2);
    t.setCursorPos(5, 1);
    for (0..3) |_| try t.index();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(-1, (try testOnlyPlacement(&state)).y);
    const generation = state.imagePlacementsGeneration();

    t.scrollViewport(.{ .delta = -2 });
    try state.update(alloc, &t);
    try testing.expectEqual(1, (try testOnlyPlacement(&state)).y);
    const scrolled = state.imagePlacementsGeneration();
    try testing.expect(generation != scrolled);

    // Stable on a second update with no changes.
    try state.update(alloc, &t);
    try testing.expectEqual(scrolled, state.imagePlacementsGeneration());
}

test "placements_generation: changes on a storage mutation" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    try testImagesGenerationScene(&t);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var generation = state.imagePlacementsGeneration();

    // Add a placement.
    try testFixedPlacement(&t, 4, 5, 0, 1, 1);
    try state.update(alloc, &t);
    try testing.expect(generation != state.imagePlacementsGeneration());
    try testing.expectEqual(3, testPlacementCount(&state));
    generation = state.imagePlacementsGeneration();

    // Delete it again.
    const storage = &t.screens.active.kitty_images;
    storage.delete(io, alloc, &t, .{ .id = .{ .image_id = 1, .placement_id = 4 } });
    try state.update(alloc, &t);
    try testing.expect(generation != state.imagePlacementsGeneration());
    try testing.expectEqual(2, testPlacementCount(&state));
    generation = state.imagePlacementsGeneration();

    // Any mutation, even one that doesn't move anything.
    storage.markMutated(io);
    try state.update(alloc, &t);
    try testing.expect(generation != state.imagePlacementsGeneration());
}

test "placements_generation: changes on a region scroll that moves a fixed placement" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 6, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    try t.switchScreenMode(.@"1049", true);

    try testFixedImage(&t, 1);
    try testFixedPlacement(&t, 1, 2, 3, 1, 1);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(3, (try testOnlyPlacement(&state)).y);
    const generation = state.imagePlacementsGeneration();

    const storage = &t.screens.active.kitty_images;
    const storage_generation = storage.generation;
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);
    try t.index();
    try testing.expectEqual(storage_generation, storage.generation);
    try state.update(alloc, &t);
    try testing.expectEqual(2, (try testOnlyPlacement(&state)).y);
    try testing.expect(generation != state.imagePlacementsGeneration());
}
