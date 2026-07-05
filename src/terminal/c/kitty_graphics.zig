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
const Result = @import("result.zig").Result;

/// C: GhosttyKittyGraphics
pub const KittyGraphics = if (build_options.kitty_graphics)
    *kitty_storage.ImageStorage
else
    *anyopaque;

/// C: GhosttyKittyGraphicsImage
pub const ImageHandle = if (build_options.kitty_graphics)
    ?*const Image
else
    ?*const anyopaque;

/// C: GhosttyKittyGraphicsPlacementIterator
pub const PlacementIterator = if (build_options.kitty_graphics)
    ?*PlacementIteratorWrapper
else
    ?*anyopaque;

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
        layer_filter: PlacementLayer = .all,
    }
else
    void;

/// C: GhosttyKittyGraphicsData
pub const Data = enum(c_int) {
    invalid = 0,
    placement_iterator = 1,
    generation = 2,

    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .invalid => void,
            .placement_iterator => PlacementIterator,
            .generation => u64,
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
        };
    }
};

pub fn get(
    graphics_: KittyGraphics,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            graphics_,
            comptime_data,
            @ptrCast(@alignCast(out)),
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
                .layer_filter = it.layer_filter,
            };
        },
        .generation => out.* = storage.generation,
    }
    return .success;
}

/// C: GhosttyKittyPlacementLayer
pub const PlacementLayer = enum(c_int) {
    all = 0,
    below_bg = 1,
    below_text = 2,
    above_text = 3,

    fn matches(self: PlacementLayer, z: i32) bool {
        return switch (self) {
            .all => true,
            .below_bg => z < std.math.minInt(i32) / 2,
            .below_text => z >= std.math.minInt(i32) / 2 and z < 0,
            .above_text => z >= 0,
        };
    }
};

/// C: GhosttyKittyGraphicsPlacementIteratorOption
pub const PlacementIteratorOption = enum(c_int) {
    layer = 0,

    pub fn InType(comptime self: PlacementIteratorOption) type {
        return switch (self) {
            .layer => PlacementLayer,
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
    data_ptr = 7,
    data_len = 8,
    generation = 9,

    pub fn OutType(comptime self: ImageData) type {
        return switch (self) {
            .invalid => void,
            .id, .number, .width, .height => u32,
            .format => ImageFormat,
            .compression => ImageCompression,
            .data_ptr => [*]const u8,
            .data_len => usize,
            .generation => u64,
        };
    }
};

pub fn image_get_handle(
    graphics_: KittyGraphics,
    image_id: u32,
) callconv(lib.calling_conv) ImageHandle {
    if (comptime !build_options.kitty_graphics) return null;

    const storage = graphics_;
    return storage.images.getPtr(image_id);
}

pub fn image_get(
    image_: ImageHandle,
    data: ImageData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| imageGetTyped(
            image_,
            comptime_data,
            @ptrCast(@alignCast(out)),
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
    if (comptime !build_options.kitty_graphics) return .no_value;

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
        .data_ptr => out.* = image.data.ptr,
        .data_len => out.* = image.data.len,
        .generation => out.* = image.generation,
    }

    return .success;
}

pub fn placement_iterator_new(
    alloc_: ?*const CAllocator,
    out: *PlacementIterator,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) {
        out.* = null;
        return .no_value;
    }
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
    if (comptime !build_options.kitty_graphics) return;
    const iter = iter_ orelse return;
    iter.alloc.destroy(iter);
}

pub fn placement_iterator_set(
    iter_: PlacementIterator,
    option: PlacementIteratorOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(PlacementIteratorOption, @intFromEnum(option)) catch {
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| placementIteratorSetTyped(
            iter_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return .invalid_value)),
        ),
    };
}

fn placementIteratorSetTyped(
    iter_: PlacementIterator,
    comptime option: PlacementIteratorOption,
    value: *const option.InType(),
) Result {
    const iter = iter_ orelse return .invalid_value;
    switch (option) {
        .layer => iter.layer_filter = value.*,
    }
    return .success;
}

pub fn placement_iterator_next(iter_: PlacementIterator) callconv(lib.calling_conv) bool {
    if (comptime !build_options.kitty_graphics) return false;

    const iter = iter_ orelse return false;
    while (iter.inner.next()) |entry| {
        if (iter.layer_filter.matches(entry.value_ptr.z)) {
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
    if (comptime !build_options.kitty_graphics) return .no_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| placementGetTyped(
            iter_,
            comptime_data,
            @ptrCast(@alignCast(out)),
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
    if (comptime !build_options.kitty_graphics) return .no_value;

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
    }

    return .success;
}

pub fn placement_rect(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out: *selection_c.CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

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
    out_width: *u32,
    out_height: *u32,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

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
    out_cols: *u32,
    out_rows: *u32,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

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
    out_col: *i32,
    out_row: *i32,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

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
    out_x: *u32,
    out_y: *u32,
    out_width: *u32,
    out_height: *u32,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const p = entry.value_ptr;

    // Apply "0 = full image dimension" convention, then clamp to image bounds.
    const x = @min(p.source_x, image.width);
    const y = @min(p.source_y, image.height);
    const w = @min(if (p.source_width > 0) p.source_width else image.width, image.width - x);
    const h = @min(if (p.source_height > 0) p.source_height else image.height, image.height - y);

    out_x.* = x;
    out_y.* = y;
    out_width.* = w;
    out_height.* = h;

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
};

pub fn placement_render_info(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_: ?*PlacementRenderInfo,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const out = out_ orelse return .invalid_value;
    if (out.size < @sizeOf(PlacementRenderInfo)) return .invalid_value;

    const p = entry.value_ptr;

    const ps = p.pixelSize(image.*, wrapper.terminal);
    out.pixel_width = ps.width;
    out.pixel_height = ps.height;

    const gs = p.gridSize(image.*, wrapper.terminal);
    out.grid_cols = gs.cols;
    out.grid_rows = gs.rows;

    const vp = computeViewportPos(p, image, wrapper.terminal);
    out.viewport_col = vp.col;
    out.viewport_row = vp.row;
    out.viewport_visible = vp.visible;

    const x = @min(p.source_x, image.width);
    const y = @min(p.source_y, image.height);
    out.source_x = x;
    out.source_y = y;
    out.source_width = @min(if (p.source_width > 0) p.source_width else image.width, image.width - x);
    out.source_height = @min(if (p.source_height > 0) p.source_height else image.height, image.height - y);

    return .success;
}

/// Compute viewport-relative position of a placement.
///
/// Converts the placement's internal pin to viewport-relative column
/// and row coordinates by getting screen-absolute coordinates for
/// both the pin and the viewport origin, then subtracting to get
/// viewport-relative coordinates. The row value can be negative when
/// the placement's origin has scrolled above the top of the viewport.
///
/// A placement is considered not visible if it is a virtual (unicode
/// placeholder) placement, or if it is fully off-screen (its bottom
/// edge is above the viewport or its top edge is at or below the
/// viewport's last row).
fn computeViewportPos(
    p: *const kitty_storage.ImageStorage.Placement,
    image: *const Image,
    t: *Terminal,
) struct { col: i32, row: i32, visible: bool } {
    // Virtual placements use unicode placeholders and don't have a
    // screen position — they are rendered inline by the text layout.
    const pin = switch (p.location) {
        .pin => |pin| pin,
        .virtual => return .{ .col = 0, .row = 0, .visible = false },
    };

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
    // placement has partially scrolled above the viewport.
    const vp_row: i32 = @as(i32, @intCast(pin_screen.screen.y)) -
        @as(i32, @intCast(vp_screen.screen.y));
    const vp_col: i32 = @intCast(pin_screen.screen.x);

    // A placement is invisible if its bottom edge (row + height)
    // is above the viewport, or its top edge is at or below the
    // viewport's last row.
    const grid_size = p.gridSize(image.*, t);
    const rows_i32: i32 = @intCast(grid_size.rows);
    const term_rows: i32 = @intCast(t.rows);
    const visible = vp_row + rows_i32 > 0 and vp_row < term_rows;

    return .{ .col = vp_col, .row = vp_row, .visible = visible };
}

test "placement_iterator new/free" {
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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

    // Filter: above_text (z >= 0) — should yield only p=1.
    var layer = PlacementLayer.above_text;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&layer)));
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    var count: u32 = 0;
    while (placement_iterator_next(iter)) {
        var z: i32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .z, @ptrCast(&z)));
        try testing.expect(z >= 0);
        count += 1;
    }
    try testing.expectEqual(1, count);

    // Filter: below_text (INT32_MIN/2 <= z < 0) — should yield only p=2.
    layer = .below_text;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&layer)));
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    count = 0;
    while (placement_iterator_next(iter)) {
        var z: i32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .z, @ptrCast(&z)));
        try testing.expect(z >= std.math.minInt(i32) / 2 and z < 0);
        count += 1;
    }
    try testing.expectEqual(1, count);

    // Filter: below_bg (z < INT32_MIN/2) — should yield only p=3.
    layer = .below_bg;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&layer)));
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    count = 0;
    while (placement_iterator_next(iter)) {
        var z: i32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .z, @ptrCast(&z)));
        try testing.expect(z < std.math.minInt(i32) / 2);
        count += 1;
    }
    try testing.expectEqual(1, count);

    // Filter: all — should yield all 3.
    layer = .all;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&layer)));
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    count = 0;
    while (placement_iterator_next(iter)) count += 1;
    try testing.expectEqual(3, count);
}

test "image_get_handle returns null for missing id" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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

    var data_len: usize = undefined;
    try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&data_len)));
    try testing.expect(data_len > 0);
}

test "placement_rect with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 5, .max_scrollback = 100 },
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
        .{ .cols = 80, .rows = 5, .max_scrollback = 100 },
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
        .{ .cols = 80, .rows = 5, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 5, .max_scrollback = 100 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
}

test "placement_render_info off-screen sets viewport_visible false" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 5, .max_scrollback = 100 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&len1)));
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
        try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&len2)));

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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
    var data_len: usize = 0;
    try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&data_len)));
    try testing.expectEqual(3, data_len);

    var data_ptr: [*]const u8 = undefined;
    try testing.expectEqual(Result.success, image_get(img, .data_ptr, @ptrCast(&data_ptr)));
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x00 }, data_ptr[0..data_len]);
}

test "generation never recurs across resets and screen switches" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 0 },
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
