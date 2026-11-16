const std = @import("std");
const testing = std.testing;
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const kitty_storage = @import("../kitty/graphics_storage.zig");
const kitty_cmd = @import("../kitty/graphics_command.zig");
const Image = @import("../kitty/graphics_image.zig").Image;
const grid_ref = @import("grid_ref.zig");
const selection_c = @import("selection.zig");
const terminal_c = @import("terminal.zig");
const Terminal = @import("../Terminal.zig");
const PageList = @import("../PageList.zig");
const Result = @import("result.zig").Result;
const RenderState = @import("../render.zig").RenderState;

/// C: GhosttyKittyGraphics
pub const KittyGraphics = if (build_options.kitty_graphics)
    *kitty_storage.ImageStorage
else
    *DisabledGraphics;

/// C: GhosttyKittyGraphicsImage
pub const ImageHandle = if (build_options.kitty_graphics)
    ?*const Image
else
    ?*const anyopaque;

/// C: GhosttyKittyGraphicsPlacementIterator
pub const PlacementIterator = if (build_options.kitty_graphics)
    ?*PlacementIteratorWrapper
else
    ?*DisabledPlacementIterator;

/// Stand-ins for the handle types when Kitty graphics is disabled. Each is
/// its own opaque type, not `anyopaque`, so the type manifest in types.zig
/// can tell the handles apart from each other and from userdata pointers
/// and describe them the same way in every build.
const DisabledGraphics = opaque {};
const DisabledPlacementIterator = opaque {};

const PlacementMap = if (build_options.kitty_graphics)
    std.AutoHashMapUnmanaged(
        kitty_storage.ImageStorage.PlacementKey,
        kitty_storage.ImageStorage.Placement,
    )
else
    void;

const PlacementIteratorWrapper = if (build_options.kitty_graphics)
    struct {
        alloc: std.mem.Allocator,
        inner: PlacementMap.Iterator = undefined,
        entry: ?PlacementMap.Entry = null,
        layer_mask: u32 = 0,
    }
else
    void;

/// C: GhosttyKittyGraphicsData
pub const Data = enum(c_int) {
    invalid = 0,
    placement_iterator = 1,
    generation = 2,

    _,

    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .invalid => void,
            .placement_iterator => PlacementIterator,
            .generation => u64,
            _ => void,
        };
    }
};

/// C: GhosttyKittyGraphicsPlacementData
pub const PlacementData = enum(c_int) {
    invalid = 0,
    image_id = 1,
    placement_id = 2,
    is_virtual = 3,
    x_offset = 4,
    y_offset = 5,
    source_x = 6,
    source_y = 7,
    source_width = 8,
    source_height = 9,
    columns = 10,
    rows = 11,
    z = 12,

    _,

    pub fn OutType(comptime self: PlacementData) type {
        return switch (self) {
            .invalid => void,
            .image_id, .placement_id => u32,
            .is_virtual => bool,
            .x_offset,
            .y_offset,
            .source_x,
            .source_y,
            .source_width,
            .source_height,
            .columns,
            .rows,
            => u32,
            .z => i32,
            _ => void,
        };
    }
};

pub fn get(
    graphics_: ?KittyGraphics,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;

    return switch (data) {
        .invalid => .invalid_value,
        _ => .unsupported,
        inline else => |comptime_data| getTyped(
            graphics_ orelse return .invalid_value,
            comptime_data,
            @ptrCast(@alignCast(out orelse return .invalid_value)),
        ),
    };
}

fn getTyped(
    graphics_: KittyGraphics,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const storage = graphics_;
    switch (data) {
        .invalid => return .invalid_value,
        .placement_iterator => {
            const it = out.* orelse return .invalid_value;
            it.* = .{
                .alloc = it.alloc,
                .inner = storage.placements.iterator(),
                .layer_mask = it.layer_mask,
            };
        },
        .generation => out.* = storage.generation,
        _ => comptime unreachable,
    }
    return .success;
}

/// Every bit that a GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER
/// mask may set. Bit N stands for the GhosttyImageLayer with value N, so
/// this has one bit for each layer.
const layer_mask_all: u32 = (1 << @typeInfo(RenderState.ImageLayer).@"enum".field_names.len) - 1;

/// Whether a placement with z-index `z` is in one of the layers in `mask`.
/// A mask of 0 means no filter, so every placement matches. The layer
/// comes from the same z-index ranges the render state uses.
fn layerMaskMatches(mask: u32, z: i32) bool {
    if (mask == 0) return true;
    const layer = RenderState.imageLayerFromZ(z);
    return mask & (@as(u32, 1) << @intCast(@backingInt(layer))) != 0;
}

/// C: GhosttyKittyGraphicsPlacementIteratorOption
pub const PlacementIteratorOption = enum(c_int) {
    invalid = 0,
    layer = 1,

    _,

    pub fn InType(comptime self: PlacementIteratorOption) type {
        return switch (self) {
            .layer => u32,
            .invalid, _ => void,
        };
    }
};

/// C: GhosttyKittyImageFormat
pub const ImageFormat = kitty_cmd.Transmission.Format;

/// C: GhosttyKittyImageCompression
pub const ImageCompression = kitty_cmd.Transmission.Compression;

/// C: GhosttyKittyGraphicsImageData
pub const ImageData = enum(c_int) {
    invalid = 0,
    id = 1,
    number = 2,
    width = 3,
    height = 4,
    format = 5,
    compression = 6,
    pixels = 7,
    expected_len = 8,
    generation = 9,

    _,

    pub fn OutType(comptime self: ImageData) type {
        return switch (self) {
            .invalid => void,
            .id, .number, .width, .height => u32,
            .format => ImageFormat,
            .compression => ImageCompression,
            .pixels => lib.String,
            .expected_len => usize,
            .generation => u64,
            _ => void,
        };
    }
};

pub fn animation_tick(
    graphics_: ?KittyGraphics,
    now_ms: u64,
    next_ms: ?*u64,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;

    const out = next_ms orelse return .invalid_value;
    const storage = graphics_ orelse return .invalid_value;

    // The tick needs an Io only to hand out new generation numbers.
    // The storage handle doesn't carry one, but TinyIo has no state,
    // so a fresh one works just as well as the terminal's.
    const delay = storage.animationTick(
        terminal_c.Io.init.io(),
        now_ms,
    ) orelse return .no_value;
    // The Zig tick returns a delay. The C API returns the absolute
    // time instead, so callers don't have to remember when they
    // called.
    out.* = now_ms +| delay;
    return .success;
}

pub fn image_get_handle(
    graphics_: ?KittyGraphics,
    image_id: u32,
) callconv(lib.calling_conv) ImageHandle {
    if (comptime !lib.feature(.kitty_graphics)) return null;

    const storage = graphics_ orelse return null;
    return storage.images.getPtr(image_id);
}

pub fn image_get(
    image_: ImageHandle,
    data: ImageData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;

    return switch (data) {
        .invalid => .invalid_value,
        _ => .unsupported,
        inline else => |comptime_data| imageGetTyped(
            image_,
            comptime_data,
            @ptrCast(@alignCast(out orelse return .invalid_value)),
        ),
    };
}

pub fn image_get_multi(
    image_: ImageHandle,
    count: usize,
    keys: ?[*]const ImageData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;

    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = image_get(image_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn imageGetTyped(
    image_: ImageHandle,
    comptime data: ImageData,
    out: *data.OutType(),
) Result {
    const image = image_ orelse return .invalid_value;

    switch (data) {
        .invalid => return .invalid_value,
        .id => out.* = image.id,
        .number => out.* = image.number,
        .width => out.* = image.width,
        .height => out.* = image.height,
        .format => out.* = image.format,
        .compression => out.* = image.compression,
        // For animated images this is the current animation frame's
        // data; the image generation changes whenever the current
        // frame does, so generation-keyed caches stay coherent.
        .pixels => out.* = .init(image.renderData().bytes() orelse return .no_value),
        .expected_len => out.* = image.renderData().len(),
        .generation => out.* = image.generation,
        _ => comptime unreachable,
    }

    return .success;
}

pub fn placement_iterator_new(
    alloc_: ?*const CAllocator,
    out_: ?*PlacementIterator,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) {
        if (out_) |o| o.* = null;
        return .unsupported;
    }
    const out = out_ orelse return .invalid_value;
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(PlacementIteratorWrapper) catch {
        out.* = null;
        return .out_of_memory;
    };
    ptr.* = .{ .alloc = alloc };
    out.* = ptr;
    return .success;
}

pub fn placement_iterator_free(iter_: PlacementIterator) callconv(lib.calling_conv) void {
    if (comptime !lib.feature(.kitty_graphics)) return;
    const iter = iter_ orelse return;
    iter.alloc.destroy(iter);
}

pub fn placement_iterator_set(
    iter_: PlacementIterator,
    option: PlacementIteratorOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;

    return switch (option) {
        .invalid => .invalid_value,
        _ => .unsupported,
        inline else => |comptime_option| placementIteratorSetTyped(
            iter_,
            comptime_option,
            if (value) |ptr| @ptrCast(@alignCast(ptr)) else null,
        ),
    };
}

fn placementIteratorSetTyped(
    iter_: PlacementIterator,
    comptime option: PlacementIteratorOption,
    value: ?*const option.InType(),
) Result {
    const iter = iter_ orelse return .invalid_value;
    switch (option) {
        .layer => {
            // NULL resets to no filter, the same as a zero mask.
            const mask = if (value) |v| v.* else 0;
            if (mask & ~layer_mask_all != 0) return .invalid_value;
            iter.layer_mask = mask;
        },
        .invalid, _ => comptime unreachable,
    }
    return .success;
}

pub fn placement_iterator_next(iter_: PlacementIterator) callconv(lib.calling_conv) bool {
    if (comptime !lib.feature(.kitty_graphics)) return false;

    const iter = iter_ orelse return false;
    while (iter.inner.next()) |entry| {
        if (layerMaskMatches(iter.layer_mask, entry.value_ptr.z)) {
            iter.entry = entry;
            return true;
        }
    }
    return false;
}

pub fn placement_get(
    iter_: PlacementIterator,
    data: PlacementData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;

    return switch (data) {
        .invalid => .invalid_value,
        _ => .unsupported,
        inline else => |comptime_data| placementGetTyped(
            iter_,
            comptime_data,
            @ptrCast(@alignCast(out orelse return .invalid_value)),
        ),
    };
}

pub fn placement_get_multi(
    iter_: PlacementIterator,
    count: usize,
    keys: ?[*]const PlacementData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;

    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = placement_get(iter_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn placementGetTyped(
    iter_: PlacementIterator,
    comptime data: PlacementData,
    out: *data.OutType(),
) Result {
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;

    const key = entry.key_ptr;
    const val = entry.value_ptr;

    switch (data) {
        .invalid => return .invalid_value,
        .image_id => out.* = key.image_id,
        .placement_id => out.* = key.placement_id.id,
        .is_virtual => out.* = val.location == .virtual,
        .x_offset => out.* = val.x_offset,
        .y_offset => out.* = val.y_offset,
        .source_x => out.* = val.source_x,
        .source_y => out.* = val.source_y,
        .source_width => out.* = val.source_width,
        .source_height => out.* = val.source_height,
        .columns => out.* = val.columns,
        .rows => out.* = val.rows,
        .z => out.* = val.z,
        _ => comptime unreachable,
    }

    return .success;
}

pub fn placement_rect(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_: ?*selection_c.CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;
    const out = out_ orelse return .invalid_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const r = entry.value_ptr.rect(
        image.*,
        wrapper.terminal,
    ) orelse return .no_value;

    out.* = .{
        .start = grid_ref.CGridRef.fromPin(r.top_left),
        .end = grid_ref.CGridRef.fromPin(r.bottom_right),
        .rectangle = true,
    };

    return .success;
}

pub fn placement_pixel_size(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_width_: ?*u32,
    out_height_: ?*u32,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;
    const out_width = out_width_ orelse return .invalid_value;
    const out_height = out_height_ orelse return .invalid_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const s = entry.value_ptr.pixelSize(image.*, wrapper.terminal);

    out_width.* = s.width;
    out_height.* = s.height;

    return .success;
}

pub fn placement_grid_size(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_cols_: ?*u32,
    out_rows_: ?*u32,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;
    const out_cols = out_cols_ orelse return .invalid_value;
    const out_rows = out_rows_ orelse return .invalid_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const s = entry.value_ptr.gridSize(image.*, wrapper.terminal);

    out_cols.* = s.cols;
    out_rows.* = s.rows;

    return .success;
}

pub fn placement_viewport_pos(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_col_: ?*i32,
    out_row_: ?*i32,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;
    const out_col = out_col_ orelse return .invalid_value;
    const out_row = out_row_ orelse return .invalid_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;

    const vp = computeViewportPos(entry.value_ptr, image, wrapper.terminal);
    if (!vp.visible) return .no_value;

    out_col.* = vp.col;
    out_row.* = vp.row;

    return .success;
}

pub fn placement_source_rect(
    iter_: PlacementIterator,
    image_: ImageHandle,
    out_x_: ?*u32,
    out_y_: ?*u32,
    out_width_: ?*u32,
    out_height_: ?*u32,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;
    const out_x = out_x_ orelse return .invalid_value;
    const out_y = out_y_ orelse return .invalid_value;
    const out_width = out_width_ orelse return .invalid_value;
    const out_height = out_height_ orelse return .invalid_value;

    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const p = entry.value_ptr;

    const source = p.sourceRect(image.*);

    out_x.* = source.x;
    out_y.* = source.y;
    out_width.* = source.width;
    out_height.* = source.height;

    return .success;
}

/// C: GhosttyKittyGraphicsPlacementRenderInfo
pub const PlacementRenderInfo = extern struct {
    size: usize = @sizeOf(PlacementRenderInfo),
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    grid_cols: u32 = 0,
    grid_rows: u32 = 0,
    viewport_col: i32 = 0,
    viewport_row: i32 = 0,
    viewport_visible: bool = false,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,

    pub const sized_base = "source_height";
};

pub fn placement_render_info(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_: ?*PlacementRenderInfo,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.kitty_graphics)) return .unsupported;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const out = out_ orelse return .invalid_value;
    if (!lib.sizedCheck(.output, out)) return .invalid_value;

    const p = entry.value_ptr;
    const ps = p.pixelSize(image.*, wrapper.terminal);
    const gs = p.gridSize(image.*, wrapper.terminal);
    const vp = computeViewportPos(p, image, wrapper.terminal);
    const source = p.sourceRect(image.*);
    lib.sizedWrite(out, .{
        .pixel_width = ps.width,
        .pixel_height = ps.height,
        .grid_cols = gs.cols,
        .grid_rows = gs.rows,
        .viewport_col = vp.col,
        .viewport_row = vp.row,
        .viewport_visible = vp.visible,
        .source_x = source.x,
        .source_y = source.y,
        .source_width = source.width,
        .source_height = source.height,
    });

    return .success;
}

/// Compute viewport-relative position of a placement, for the C API
/// functions that inspect the storage. Drawing doesn't use this. The
/// render state positions placements on its own.
///
/// Converts the placement's internal pin to viewport-relative column
/// and row coordinates by getting screen-absolute coordinates for
/// both the pin and the viewport origin, then subtracting to get
/// viewport-relative coordinates. The row value can be negative when
/// the placement's origin has scrolled above the top of the viewport.
///
/// A placement is considered not visible if it is a virtual (unicode
/// placeholder) placement, its tracked content has been pruned, or it is
/// fully off-screen (its bottom edge is above the viewport or its top edge is
/// at or below the viewport's last row).
fn computeViewportPos(
    p: *const kitty_storage.ImageStorage.Placement,
    image: *const Image,
    t: *Terminal,
) struct { col: i32, row: i32, visible: bool } {
    // Virtual placements use unicode placeholders and don't have a
    // screen position of their own. Relative placements are anchored at
    // the root of their parent chain, offset by the accumulated chain
    // offsets. A chain rooted at a virtual placement has no resolvable
    // position here: its origin is the parent's placeholder cells, which
    // the render state finds while it scans the captured rows.
    const origin: struct {
        pin: *const PageList.Pin,
        col_offset: i32 = 0,
        row_offset: i32 = 0,
    } = switch (p.location) {
        .pin => |pin| .{ .pin = pin },
        .virtual => return .{ .col = 0, .row = 0, .visible = false },
        .relative => |rel| origin: {
            const storage = &t.screens.active.kitty_images;
            const chain = storage.resolveChain(rel) orelse
                return .{ .col = 0, .row = 0, .visible = false };
            switch (chain.root.location) {
                .pin => |root_pin| break :origin .{
                    .pin = root_pin,
                    .col_offset = chain.horizontal_offset,
                    .row_offset = chain.vertical_offset,
                },
                .virtual => return .{ .col = 0, .row = 0, .visible = false },
                .relative => unreachable, // resolveChain roots are never relative
            }
        },
    };

    const pin = origin.pin;
    if (pin.garbage) return .{ .col = 0, .row = 0, .visible = false };

    // Convert both the placement's pin and the viewport's top-left
    // corner to screen-absolute coordinates so we can subtract them
    // to get viewport-relative coordinates.
    const pages = &t.screens.active.pages;
    const pin_screen = pages.pointFromPin(.screen, pin.*) orelse
        return .{ .col = 0, .row = 0, .visible = false };
    const vp_tl = pages.getTopLeft(.viewport);
    const vp_screen = pages.pointFromPin(.screen, vp_tl) orelse
        return .{ .col = 0, .row = 0, .visible = false };

    // Subtracting viewport origin from the pin gives us viewport-
    // relative coordinates. The row can be negative when the
    // placement has partially scrolled above the viewport, and both
    // can be negative for relative placements with negative offsets.
    const vp_row: i32 = (@as(i32, @intCast(pin_screen.screen.y)) -
        @as(i32, @intCast(vp_screen.screen.y))) +| origin.row_offset;
    const vp_col: i32 = @as(i32, @intCast(pin_screen.screen.x)) +|
        origin.col_offset;

    // A placement is invisible if its bottom edge (row + height) is
    // above the viewport, or its top edge is at or below the viewport's
    // last row. The same applies horizontally: a pin's column is always
    // in bounds, but a relative placement's offsets can push it fully
    // off either side.
    const grid_size = p.gridSize(image.*, t);
    const bottom_row = @as(i64, vp_row) + @as(i64, grid_size.rows);
    const right_col = @as(i64, vp_col) + @as(i64, grid_size.cols);
    const visible = bottom_row > 0 and vp_row < @as(i32, t.rows) and
        right_col > 0 and vp_col < @as(i32, t.cols);

    return .{ .col = vp_col, .row = vp_row, .visible = visible };
}

test "placement_iterator new/free" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    try testing.expect(iter != null);
    placement_iterator_free(iter);
}

test "placement_iterator free null" {
    placement_iterator_free(null);
}

test "placement_iterator next on empty storage" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(!placement_iterator_next(iter));
}

test "placement_iterator get before next returns invalid" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    var image_id: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_get(iter, .image_id, @ptrCast(&image_id)));
}

test "placement_iterator with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit and display a 1x2 RGB image (image_id=1, placement_id=1).
    // a=T (transmit+display), t=d (direct), f=24 (RGB), i=1, p=1
    // s=1,v=2 (1x2 pixels), c=10,r=1 (10 cols, 1 row)
    // //////// = 8 base64 chars = 6 bytes = 1*2*3 RGB bytes
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    // Should have exactly one placement.
    try testing.expect(placement_iterator_next(iter));

    var image_id: u32 = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .image_id, @ptrCast(&image_id)));
    try testing.expectEqual(1, image_id);

    var placement_id: u32 = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .placement_id, @ptrCast(&placement_id)));
    try testing.expectEqual(1, placement_id);

    var is_virtual: bool = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .is_virtual, @ptrCast(&is_virtual)));
    try testing.expect(!is_virtual);

    // No more placements.
    try testing.expect(!placement_iterator_next(iter));
}

test "placement_iterator with multiple placements" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit image 1 then display it twice with different placement IDs.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display1 = "\x1b_Ga=p,i=1,p=1,c=10,r=1;\x1b\\";
    const display2 = "\x1b_Ga=p,i=1,p=2,c=5,r=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display1.ptr, display1.len);
    terminal_c.vt_write(t, display2.ptr, display2.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    // Count placements and collect image IDs.
    var count: usize = 0;
    var seen_p1 = false;
    var seen_p2 = false;
    while (placement_iterator_next(iter)) {
        count += 1;

        var image_id: u32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .image_id, @ptrCast(&image_id)));
        try testing.expectEqual(1, image_id);

        var placement_id: u32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .placement_id, @ptrCast(&placement_id)));
        if (placement_id == 1) seen_p1 = true;
        if (placement_id == 2) seen_p2 = true;
    }

    try testing.expectEqual(2, count);
    try testing.expect(seen_p1);
    try testing.expect(seen_p2);
}

test "placement_iterator_set layer filter" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit image 1.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);

    // Display with z=5 (above text), z=-1 (below text), z=-1073741825 (below bg).
    // INT32_MIN/2 = -1073741824, so -1073741825 < INT32_MIN/2.
    const d1 = "\x1b_Ga=p,i=1,p=1,z=5;\x1b\\";
    const d2 = "\x1b_Ga=p,i=1,p=2,z=-1;\x1b\\";
    const d3 = "\x1b_Ga=p,i=1,p=3,z=-1073741825;\x1b\\";
    terminal_c.vt_write(t, d1.ptr, d1.len);
    terminal_c.vt_write(t, d2.ptr, d2.len);
    terminal_c.vt_write(t, d3.ptr, d3.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    // The three placements are in different layers. Placement 1 is above
    // the text (mask bit 2), placement 2 is below the text (bit 1), and
    // placement 3 is below the backgrounds (bit 0). Each row pairs a mask
    // with the placements it visits, written as a set where bit N means
    // placement N. Together the rows cover every mask.
    const cases = [_]struct { mask: u32, ids: u32 }{
        .{ .mask = 0, .ids = 0b1110 },
        .{ .mask = 0b001, .ids = 0b1000 },
        .{ .mask = 0b010, .ids = 0b0100 },
        .{ .mask = 0b011, .ids = 0b1100 },
        .{ .mask = 0b100, .ids = 0b0010 },
        .{ .mask = 0b101, .ids = 0b1010 },
        .{ .mask = 0b110, .ids = 0b0110 },
        .{ .mask = 0b111, .ids = 0b1110 },
    };
    for (cases) |case| {
        try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&case.mask)));
        try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
        var ids: u32 = 0;
        while (placement_iterator_next(iter)) {
            var id: u32 = undefined;
            try testing.expectEqual(Result.success, placement_get(iter, .placement_id, @ptrCast(&id)));
            ids |= @as(u32, 1) << @intCast(id);
        }
        try testing.expectEqual(case.ids, ids);
    }

    // A bit that matches no layer is rejected, and the previous mask stays.
    const one_layer: u32 = 0b100;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&one_layer)));
    const unknown_bit: u32 = 0b1000;
    try testing.expectEqual(Result.invalid_value, placement_iterator_set(iter, .layer, @ptrCast(&unknown_bit)));
    try testing.expectEqual(one_layer, iter.?.layer_mask);

    // NULL resets to no filter.
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, null));
    try testing.expectEqual(@as(u32, 0), iter.?.layer_mask);
}

test "image_get_handle returns null for missing id" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    try testing.expectEqual(@as(ImageHandle, null), image_get_handle(graphics, 999));
}

test "image_get_handle and image_get with transmitted image" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit a 1x2 RGB image with image_id=1.
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var id: u32 = undefined;
    try testing.expectEqual(Result.success, image_get(img, .id, @ptrCast(&id)));
    try testing.expectEqual(1, id);

    var w: u32 = undefined;
    try testing.expectEqual(Result.success, image_get(img, .width, @ptrCast(&w)));
    try testing.expectEqual(1, w);

    var h: u32 = undefined;
    try testing.expectEqual(Result.success, image_get(img, .height, @ptrCast(&h)));
    try testing.expectEqual(2, h);

    var fmt: ImageFormat = undefined;
    try testing.expectEqual(Result.success, image_get(img, .format, @ptrCast(&fmt)));
    try testing.expectEqual(.rgb, fmt);

    var comp: ImageCompression = undefined;
    try testing.expectEqual(Result.success, image_get(img, .compression, @ptrCast(&comp)));
    try testing.expectEqual(.none, comp);

    var expected_len: usize = undefined;
    try testing.expectEqual(Result.success, image_get(img, .expected_len, @ptrCast(&expected_len)));
    try testing.expect(expected_len > 0);
}

test "image_get exposes pending metadata without a data pointer" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const alloc = lib.alloc.default(&lib.alloc.test_allocator);
    const pending = try graphics.addPendingImage(testing.io, alloc, terminal_c.zigTerminal(t).?.screens.active, .{
        .id = 42,
        .number = 7,
        .width = 1,
        .height = 4,
        .format = .rgb,
        .data = .{ .pending = 12 },
    });

    const img = image_get_handle(graphics, 42);
    try testing.expect(img != null);

    var number: u32 = 0;
    try testing.expectEqual(Result.success, image_get(img, .number, @ptrCast(&number)));
    try testing.expectEqual(@as(u32, 7), number);

    // Pending: the expected length is known, the pixels are not.
    var expected_len: usize = 0;
    try testing.expectEqual(Result.success, image_get(img, .expected_len, @ptrCast(&expected_len)));
    try testing.expectEqual(@as(usize, 12), expected_len);

    var image_pixels: lib.String = undefined;
    try testing.expectEqual(Result.no_value, image_get(img, .pixels, @ptrCast(&image_pixels)));

    const pixels = try alloc.alloc(u8, 12);
    @memset(pixels, '*');
    try testing.expect(pending.complete(graphics, testing.io, pixels));
    const completed_img = image_get_handle(graphics, 42);
    try testing.expect(completed_img != null);
    // Complete: the pixels carry their length, equal to the expected one.
    try testing.expectEqual(Result.success, image_get(completed_img, .pixels, @ptrCast(&image_pixels)));
    try testing.expectEqualSlices(u8, pixels, image_pixels.ptr[0..image_pixels.len]);
    try testing.expectEqual(Result.success, image_get(completed_img, .expected_len, @ptrCast(&expected_len)));
    try testing.expectEqual(image_pixels.len, expected_len);
}

test "placement_rect with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Set cell size so grid calculations are deterministic.
    // 80 cols * 10px = 800px, 24 rows * 20px = 480px.
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display a 1x2 RGB image at cursor (0,0).
    // c=10,r=1 => 10 columns, 1 row.
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, placement_rect(iter, img, t, &sel));

    // Placement starts at cursor origin (0,0).
    try testing.expectEqual(0, sel.start.x);
    try testing.expectEqual(0, sel.start.y);

    // 10 columns wide, 1 row tall => bottom-right is (9, 0).
    try testing.expectEqual(9, sel.end.x);
    try testing.expectEqual(0, sel.end.y);

    try testing.expect(sel.rectangle);
}

test "placement_rect null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.invalid_value, placement_rect(null, null, null, &sel));
}

test "placement_pixel_size with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // 80 cols * 10px = 800px, 24 rows * 20px = 480px.
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display a 1x2 RGB image with c=10,r=1.
    // 10 cols * 10px = 100px width, 1 row * 20px = 20px height.
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.success, placement_pixel_size(iter, img, t, &w, &h));

    try testing.expectEqual(100, w);
    try testing.expectEqual(20, h);
}

test "placement_pixel_size null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_pixel_size(null, null, null, &w, &h));
}

test "placement_grid_size with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // 80 cols * 10px = 800px, 24 rows * 20px = 480px.
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display a 1x2 RGB image with c=10,r=1.
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var cols: u32 = undefined;
    var rows: u32 = undefined;
    try testing.expectEqual(Result.success, placement_grid_size(iter, img, t, &cols, &rows));

    try testing.expectEqual(10, cols);
    try testing.expectEqual(1, rows);
}

test "placement_grid_size null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var cols: u32 = undefined;
    var rows: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_grid_size(null, null, null, &cols, &rows));
}

test "placement_viewport_pos with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display at cursor (0,0).
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.success, placement_viewport_pos(iter, img, t, &col, &row));

    try testing.expectEqual(0, col);
    try testing.expectEqual(0, row);
}

test "placement_viewport_pos fully off-screen above" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    // Transmit image, then display at cursor (0,0) spanning 1 row.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    // Scroll the image completely off: 10 newlines in a 5-row terminal
    // scrolls by 5+ rows, so a 1-row image at row 0 is fully gone.
    const scroll = "\n\n\n\n\n\n\n\n\n\n";
    terminal_c.vt_write(t, scroll.ptr, scroll.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.no_value, placement_viewport_pos(iter, img, t, &col, &row));
}

test "placement_viewport_pos top off-screen" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    // Transmit image, display at cursor (0,0) spanning 4 rows.
    // C=1 prevents cursor movement after display.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=4,C=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    // Scroll by 2: cursor starts at row 0, 4 newlines to reach bottom,
    // then 2 more to scroll by 2. Image top-left moves to vp_row=-2,
    // but bottom rows -2+4=2 > 0 so it's still partially visible.
    const scroll = "\n\n\n\n\n\n";
    terminal_c.vt_write(t, scroll.ptr, scroll.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.success, placement_viewport_pos(iter, img, t, &col, &row));
    try testing.expectEqual(0, col);
    try testing.expectEqual(-2, row);
}

test "placement_viewport_pos bottom off-screen" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    // Transmit image, move cursor to row 3 (1-based: row 4), display spanning 4 rows.
    // C=1 prevents cursor movement after display.
    // Image occupies rows 3-6 but viewport only has rows 0-4, so bottom is clipped.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const cursor = "\x1b[4;1H";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=4,C=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, cursor.ptr, cursor.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.success, placement_viewport_pos(iter, img, t, &col, &row));
    try testing.expectEqual(0, col);
    try testing.expectEqual(3, row);
}

test "placement_viewport_pos top and bottom off-screen" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    // Transmit image, display at cursor (0,0) spanning 10 rows.
    // C=1 prevents cursor movement after display.
    // After scrolling by 3, image occupies vp rows -3..6, viewport is 0..4,
    // so both top and bottom are clipped but center is visible.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=10,C=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    // Scroll by 3: 4 newlines to reach bottom + 3 more to scroll.
    const scroll = "\n\n\n\n\n\n\n";
    terminal_c.vt_write(t, scroll.ptr, scroll.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.success, placement_viewport_pos(iter, img, t, &col, &row));
    try testing.expectEqual(0, col);
    try testing.expectEqual(-3, row);
}

test "placement_viewport_pos null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_viewport_pos(null, null, null, &col, &row));
}

test "placement_source_rect defaults to full image" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display a 1x2 RGB image with no source rect specified.
    // source_width=0 and source_height=0 should resolve to full image (1x2).
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var x: u32 = undefined;
    var y: u32 = undefined;
    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.success, placement_source_rect(iter, img, &x, &y, &w, &h));
    try testing.expectEqual(0, x);
    try testing.expectEqual(0, y);
    try testing.expectEqual(1, w);
    try testing.expectEqual(2, h);
}

test "placement_source_rect with explicit source rect" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit a 4x4 RGBA image (64 bytes = 4*4*4).
    // Base64 of 64 zero bytes: 88 chars (21 full groups + AA== padding).
    const transmit = "\x1b_Ga=t,t=d,f=32,i=1,s=4,v=4;" ++
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==" ++
        "\x1b\\";
    // Display with explicit source rect: x=1, y=1, w=2, h=2.
    const display = "\x1b_Ga=p,i=1,p=1,x=1,y=1,w=2,h=2;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var x: u32 = undefined;
    var y: u32 = undefined;
    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.success, placement_source_rect(iter, img, &x, &y, &w, &h));
    try testing.expectEqual(1, x);
    try testing.expectEqual(1, y);
    try testing.expectEqual(2, w);
    try testing.expectEqual(2, h);
}

test "placement_source_rect clamps to image bounds" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit a 4x4 RGBA image (64 bytes = 4*4*4).
    const transmit = "\x1b_Ga=t,t=d,f=32,i=1,s=4,v=4;" ++
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==" ++
        "\x1b\\";
    // Display with source rect that exceeds image bounds: x=3, y=3, w=10, h=10.
    // Should clamp to x=3, y=3, w=1, h=1.
    const display = "\x1b_Ga=p,i=1,p=1,x=3,y=3,w=10,h=10;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var x: u32 = undefined;
    var y: u32 = undefined;
    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.success, placement_source_rect(iter, img, &x, &y, &w, &h));
    try testing.expectEqual(3, x);
    try testing.expectEqual(3, y);
    try testing.expectEqual(1, w);
    try testing.expectEqual(1, h);

    var pixel_width: u32 = undefined;
    var pixel_height: u32 = undefined;
    try testing.expectEqual(
        Result.success,
        placement_pixel_size(iter, img, t, &pixel_width, &pixel_height),
    );
    try testing.expectEqual(1, pixel_width);
    try testing.expectEqual(1, pixel_height);
}

test "placement_source_rect null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var x: u32 = undefined;
    var y: u32 = undefined;
    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_source_rect(null, null, &x, &y, &w, &h));
}

test "image_get on null returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, image_get(null, .id, @ptrCast(&id)));
}

test "placement_render_info returns all fields" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var ri: PlacementRenderInfo = .{};
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expect(ri.viewport_visible);
    try testing.expectEqual(0, ri.viewport_col);
    try testing.expectEqual(0, ri.viewport_row);
    try testing.expectEqual(10, ri.grid_cols);
    try testing.expectEqual(1, ri.grid_rows);
    try testing.expectEqual(0, ri.source_x);
    try testing.expectEqual(0, ri.source_y);
    try testing.expectEqual(1, ri.source_width);
    try testing.expectEqual(2, ri.source_height);

    // The size rule: below the base layout is rejected and nothing is
    // written, exactly the base layout is enough, and a newer caller's
    // tail is left untouched.
    ri = .{ .size = lib.sizedBaseEnd(PlacementRenderInfo) - 1 };
    try testing.expectEqual(Result.invalid_value, placement_render_info(iter, img, t, &ri));
    try testing.expectEqual(0, ri.grid_cols);
    ri = .{ .size = lib.sizedBaseEnd(PlacementRenderInfo) };
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expectEqual(2, ri.source_height);
    const Larger = extern struct { ri: PlacementRenderInfo, extra: [8]u8 };
    var large: Larger = .{ .ri = .{ .size = @sizeOf(Larger) }, .extra = @splat(0xaa) };
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &large.ri));
    try testing.expectEqual(@sizeOf(Larger), large.ri.size);
    try testing.expectEqual(10, large.ri.grid_cols);
    try testing.expectEqual(@as([8]u8, @splat(0xaa)), large.extra);

    const entry = iter.?.entry.?;
    const pin = switch (entry.value_ptr.location) {
        .pin => |pin| pin,
        .virtual, .relative => unreachable,
    };
    pin.garbage = true;

    ri = .{};
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expect(!ri.viewport_visible);

    var rect: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.no_value, placement_rect(iter, img, t, &rect));
}

test "placement_render_info handles maximum grid dimensions" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=1,r=4294967295,C=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var ri: PlacementRenderInfo = .{};
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expect(ri.viewport_visible);
    try testing.expectEqual(std.math.maxInt(u32), ri.grid_rows);
}

test "placement_render_info off-screen sets viewport_visible false" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    // Scroll the image completely off-screen.
    const scroll = "\n\n\n\n\n\n\n\n\n\n";
    terminal_c.vt_write(t, scroll.ptr, scroll.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var ri: PlacementRenderInfo = .{};
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expect(!ri.viewport_visible);
    // Other fields should still be populated.
    try testing.expectEqual(1, ri.grid_cols);
    try testing.expectEqual(1, ri.grid_rows);
    try testing.expectEqual(1, ri.source_width);
    try testing.expectEqual(2, ri.source_height);
}

test "placement_render_info null returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var ri: PlacementRenderInfo = .{};
    try testing.expectEqual(Result.invalid_value, placement_render_info(null, null, null, &ri));
}

test "image_get_multi success" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var id: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var written: usize = 0;

    const keys = [_]ImageData{ .id, .width, .height };
    var values = [_]?*anyopaque{ @ptrCast(&id), @ptrCast(&width), @ptrCast(&height) };
    try testing.expectEqual(Result.success, image_get_multi(img, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(1, id);
    try testing.expectEqual(1, width);
    try testing.expectEqual(2, height);
}

test "image_get_multi error sets out_written" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = 0;
    var written: usize = 99;

    const keys = [_]ImageData{ .id, .invalid };
    var values = [_]?*anyopaque{ @ptrCast(&id), @ptrCast(&id) };
    try testing.expectEqual(Result.invalid_value, image_get_multi(null, keys.len, &keys, &values, &written));
    try testing.expectEqual(0, written);
}

test "image_get_multi null keys returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = 0;
    var values = [_]?*anyopaque{@ptrCast(&id)};
    try testing.expectEqual(Result.invalid_value, image_get_multi(null, 1, null, &values, null));
}

test "placement_get_multi success" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var image_id: u32 = 0;
    var columns: u32 = 0;
    var z: i32 = 99;
    var written: usize = 0;

    const keys = [_]PlacementData{ .image_id, .columns, .z };
    var values = [_]?*anyopaque{ @ptrCast(&image_id), @ptrCast(&columns), @ptrCast(&z) };
    try testing.expectEqual(Result.success, placement_get_multi(iter, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(1, image_id);
    try testing.expectEqual(10, columns);
    try testing.expectEqual(0, z);
}

test "placement_get_multi error sets out_written" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = 0;
    var written: usize = 99;

    const keys = [_]PlacementData{ .image_id, .invalid };
    var values = [_]?*anyopaque{ @ptrCast(&id), @ptrCast(&id) };
    try testing.expectEqual(Result.invalid_value, placement_get_multi(null, keys.len, &keys, &values, &written));
    try testing.expectEqual(0, written);
}

test "placement_get_multi null keys returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = 0;
    var values = [_]?*anyopaque{@ptrCast(&id)};
    try testing.expectEqual(Result.invalid_value, placement_get_multi(null, 1, null, &values, null));
}

test "storage generation via get" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    // Fresh storage: generation zero.
    var gen0: u64 = 99;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen0)));
    try testing.expectEqual(0, gen0);

    // Transmit bumps the generation.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    var gen1: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen1)));
    try testing.expect(gen1 > gen0);

    // Unrelated terminal writes (plain text) do not bump it.
    const text = "hello world";
    terminal_c.vt_write(t, text.ptr, text.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    var gen2: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen2)));
    try testing.expectEqual(gen1, gen2);

    // Placement bumps it.
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=1;\x1b\\";
    terminal_c.vt_write(t, display.ptr, display.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    var gen3: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen3)));
    try testing.expect(gen3 > gen2);

    // Delete bumps it.
    const del = "\x1b_Ga=d,d=A\x1b\\";
    terminal_c.vt_write(t, del.ptr, del.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    var gen4: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen4)));
    try testing.expect(gen4 > gen3);
}

test "image generation detects same-sized retransmission" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit a 1x2 RGB image with id=1.
    const transmit1 = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit1.ptr, transmit1.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    var gen1: u64 = 0;
    var w1: u32 = 0;
    var h1: u32 = 0;
    var len1: usize = 0;
    {
        const img = image_get_handle(graphics, 1);
        try testing.expect(img != null);
        try testing.expectEqual(Result.success, image_get(img, .generation, @ptrCast(&gen1)));
        try testing.expectEqual(Result.success, image_get(img, .width, @ptrCast(&w1)));
        try testing.expectEqual(Result.success, image_get(img, .height, @ptrCast(&h1)));
        try testing.expectEqual(Result.success, image_get(img, .expected_len, @ptrCast(&len1)));
        try testing.expect(gen1 > 0);
    }

    // Retransmit the same ID with identical dimensions but different
    // pixel bytes. All size heuristics match; only the generation
    // reveals the change.
    const transmit2 = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA\x1b\\";
    terminal_c.vt_write(t, transmit2.ptr, transmit2.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    {
        const img = image_get_handle(graphics, 1);
        try testing.expect(img != null);
        var gen2: u64 = 0;
        var w2: u32 = 0;
        var h2: u32 = 0;
        var len2: usize = 0;
        try testing.expectEqual(Result.success, image_get(img, .generation, @ptrCast(&gen2)));
        try testing.expectEqual(Result.success, image_get(img, .width, @ptrCast(&w2)));
        try testing.expectEqual(Result.success, image_get(img, .height, @ptrCast(&h2)));
        try testing.expectEqual(Result.success, image_get(img, .expected_len, @ptrCast(&len2)));

        // Size heuristics are identical...
        try testing.expectEqual(w1, w2);
        try testing.expectEqual(h1, h2);
        try testing.expectEqual(len1, len2);

        // ...but the generation changed.
        try testing.expect(gen2 > gen1);
    }
}

test "image generation via image_get_multi" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var id: u32 = 0;
    var generation: u64 = 0;
    var written: usize = 0;
    const keys = [_]ImageData{ .id, .generation };
    var values = [_]?*anyopaque{ @ptrCast(&id), @ptrCast(&generation) };
    try testing.expectEqual(Result.success, image_get_multi(img, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(1, id);
    try testing.expect(generation > 0);

    // The image stamp came from the same sequence as (and here, the
    // same event as) the storage stamp.
    var storage_gen: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&storage_gen)));
    try testing.expectEqual(storage_gen, generation);
}

test "image compression and format always report decoded data" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit a zlib-compressed 1x1 RGB image (o=z). The payload is
    // base64(zlib([0xFF, 0x00, 0x00])).
    const compressed = comptime blk: {
        // zlib stream for the 3 bytes FF 00 00 (stored block).
        // 78 01: zlib header; 01: final stored block; 03 00 len;
        // FC FF nlen; FF 00 00 data; adler32 = 0x03000100 (big endian).
        const raw = [_]u8{ 0x78, 0x01, 0x01, 0x03, 0x00, 0xFC, 0xFF, 0xFF, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00 };
        var buf: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
        const enc = std.base64.standard.Encoder.encode(&buf, &raw);
        break :blk enc[0..enc.len].*;
    };
    const transmit = "\x1b_Ga=t,t=d,f=24,o=z,i=1,s=1,v=1;" ++ compressed ++ "\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    // Compression must report NONE: the data was inflated at
    // transmission time.
    var comp: ImageCompression = undefined;
    try testing.expectEqual(Result.success, image_get(img, .compression, @ptrCast(&comp)));
    try testing.expectEqual(.none, comp);

    // Data is the decoded pixels: width * height * bpp.
    var pixels: lib.String = undefined;
    try testing.expectEqual(Result.success, image_get(img, .pixels, @ptrCast(&pixels)));
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x00 }, pixels.ptr[0..pixels.len]);
}

test "generation never recurs across resets and screen switches" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    var gen: u64 = 0;

    // Transmit on the main screen.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    const gen_main = gen;
    try testing.expect(gen_main > 0);

    // Switch to the alternate screen: its storage is untouched, so its
    // generation is zero (which always means "empty").
    const alt_on = "\x1b[?1049h";
    terminal_c.vt_write(t, alt_on.ptr, alt_on.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    try testing.expectEqual(0, gen);

    // A transmit on the alt screen draws from the same global sequence,
    // so its stamp is strictly greater than anything seen on the main
    // screen: an embedder keying a cache on the generation value alone
    // can never confuse the two storages.
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    const gen_alt = gen;
    try testing.expect(gen_alt > gen_main);

    // Back to the main screen: its generation is unchanged.
    const alt_off = "\x1b[?1049l";
    terminal_c.vt_write(t, alt_off.ptr, alt_off.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    try testing.expectEqual(gen_main, gen);

    // Reset zeroes the storage (empty), and the next mutation continues
    // from the global sequence: past values are never reused for
    // different content.
    terminal_c.reset(t);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    try testing.expectEqual(0, gen);

    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    try testing.expect(gen > gen_alt);
}

test "animation_tick advances a running animation" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Place a red 1x1 RGBA image and add a blue second frame that
    // shows for 40ms. The first frame starts with no display time,
    // so give it 30ms. Then start looping playback.
    const cmds = "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\" ++
        "\x1b_Ga=f,f=32,i=1,s=1,v=1,z=40;AAD//w==\x1b\\" ++
        "\x1b_Ga=a,i=1,r=1,z=30\x1b\\" ++
        "\x1b_Ga=a,i=1,s=3\x1b\\";
    terminal_c.vt_write(t, cmds.ptr, cmds.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    const Snapshot = struct {
        gen: u64,
        pixel: [4]u8,

        fn read(g: KittyGraphics) !@This() {
            const img = image_get_handle(g, 1) orelse return error.TestUnexpectedResult;
            var gen: u64 = 0;
            var pixels: lib.String = undefined;
            try testing.expectEqual(Result.success, image_get(img, .generation, @ptrCast(&gen)));
            try testing.expectEqual(Result.success, image_get(img, .pixels, @ptrCast(&pixels)));
            return .{ .gen = gen, .pixel = pixels.ptr[0..4].* };
        }
    };
    const red: [4]u8 = .{ 255, 0, 0, 255 };
    const blue: [4]u8 = .{ 0, 0, 255, 255 };

    // The first tick starts the first frame's 30ms timer.
    var next: u64 = 0;
    const s0 = try Snapshot.read(graphics);
    try testing.expectEqualSlices(u8, &red, &s0.pixel);
    try testing.expectEqual(Result.success, animation_tick(graphics, 1000, &next));
    try testing.expectEqual(@as(u64, 1030), next);
    try testing.expectEqual(s0, try Snapshot.read(graphics));

    // An early tick changes nothing and reports the same time.
    try testing.expectEqual(Result.success, animation_tick(graphics, 1010, &next));
    try testing.expectEqual(@as(u64, 1030), next);
    try testing.expectEqual(s0, try Snapshot.read(graphics));

    // On time, the blue frame shows with a new generation.
    try testing.expectEqual(Result.success, animation_tick(graphics, 1030, &next));
    try testing.expectEqual(@as(u64, 1070), next);
    const s1 = try Snapshot.read(graphics);
    try testing.expectEqualSlices(u8, &blue, &s1.pixel);
    try testing.expect(s1.gen > s0.gen);

    // It then loops back to the first frame.
    try testing.expectEqual(Result.success, animation_tick(graphics, 1070, &next));
    try testing.expectEqual(@as(u64, 1100), next);
    const s2 = try Snapshot.read(graphics);
    try testing.expectEqualSlices(u8, &red, &s2.pixel);
    try testing.expect(s2.gen > s1.gen);

    // After a stop command (a=a,s=1) the tick reports nothing to
    // play and leaves next_ms and the image alone.
    const stop = "\x1b_Ga=a,i=1,s=1\x1b\\";
    terminal_c.vt_write(t, stop.ptr, stop.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    next = 42;
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 1100, &next));
    try testing.expectEqual(@as(u64, 42), next);
    try testing.expectEqual(s2, try Snapshot.read(graphics));
}

test "animation_tick without animations returns no value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    var next: u64 = 0;

    // Empty storage.
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 0, &next));

    // A placed static image.
    const transmit = "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 0, &next));
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 1000, &next));
}

test "animation_tick null out returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.invalid_value, animation_tick(graphics, 0, null));
}
