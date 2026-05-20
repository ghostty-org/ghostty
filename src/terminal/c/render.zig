const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const colorpkg = @import("../color.zig");
const cursorpkg = @import("../cursor.zig");
const page = @import("../page.zig");
const size = @import("../size.zig");
const Style = @import("../style.zig").Style;
const terminal_c = @import("terminal.zig");
const ZigTerminal = @import("../Terminal.zig");
const renderpkg = @import("../render.zig");
const Result = @import("result.zig").Result;
const row = @import("row.zig");
const style_c = @import("style.zig");

const log = std.log.scoped(.render_state_c);

const RenderStateWrapper = struct {
    alloc: std.mem.Allocator,
    state: renderpkg.RenderState = .empty,
};

const RowIteratorWrapper = struct {
    alloc: std.mem.Allocator,

    /// The current index (also y value) into the row list.
    y: ?size.CellCountInt,

    /// These are the raw pointers into the render state data.
    raws: []const page.Row,
    cells: []const std.MultiArrayList(renderpkg.RenderState.Cell),
    dirty: []bool,

    /// The color palette from the render state, needed to resolve
    /// palette-indexed background colors on cells.
    palette: *const colorpkg.Palette,
};

const RowCellsWrapper = struct {
    alloc: std.mem.Allocator,
    x: ?size.CellCountInt,
    raws: []const page.Cell,
    graphemes: []const []const u21,
    styles: []const Style,

    /// The color palette, needed to resolve palette-indexed background colors.
    palette: *const colorpkg.Palette,
};

/// C: GhosttyRenderState
pub const RenderState = ?*RenderStateWrapper;

/// C: GhosttyRenderStateRowIterator
pub const RowIterator = ?*RowIteratorWrapper;

/// C: GhosttyRenderStateRowCells
pub const RowCells = ?*RowCellsWrapper;

/// C: GhosttyRenderStateDirty
pub const Dirty = renderpkg.RenderState.Dirty;

/// C: GhosttyRenderStateCursorVisualStyle
pub const CursorVisualStyle = enum(c_int) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,

    pub fn fromCursorStyle(s: cursorpkg.Style) CursorVisualStyle {
        return switch (s) {
            .bar => .bar,
            .block => .block,
            .underline => .underline,
            .block_hollow => .block_hollow,
        };
    }
};

/// C: GhosttyRenderStateData
pub const Data = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    dirty = 3,
    row_iterator = 4,
    color_background = 5,
    color_foreground = 6,
    color_cursor = 7,
    color_cursor_has_value = 8,
    color_palette = 9,
    cursor_visual_style = 10,
    cursor_visible = 11,
    cursor_blinking = 12,
    cursor_password_input = 13,
    cursor_viewport_has_value = 14,
    cursor_viewport_x = 15,
    cursor_viewport_y = 16,
    cursor_viewport_wide_tail = 17,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .invalid => void,
            .cols, .rows => size.CellCountInt,
            .dirty => Dirty,
            .row_iterator => RowIterator,
            .color_background, .color_foreground, .color_cursor => colorpkg.RGB.C,
            .color_cursor_has_value => bool,
            .color_palette => colorpkg.PaletteC,
            .cursor_visual_style => CursorVisualStyle,
            .cursor_visible, .cursor_blinking, .cursor_password_input => bool,
            .cursor_viewport_has_value, .cursor_viewport_wide_tail => bool,
            .cursor_viewport_x, .cursor_viewport_y => size.CellCountInt,
        };
    }
};

/// C: GhosttyRenderStateOption
pub const SetOption = enum(c_int) {
    dirty = 0,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: SetOption) type {
        return switch (self) {
            .dirty => Dirty,
        };
    }
};

/// C: GhosttyRenderStateColors
pub const Colors = extern struct {
    size: usize = @sizeOf(Colors),
    background: colorpkg.RGB.C,
    foreground: colorpkg.RGB.C,
    cursor: colorpkg.RGB.C,
    cursor_has_value: bool,
    palette: colorpkg.PaletteC,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *RenderState,
) callconv(lib.calling_conv) Result {
    result.* = new_(alloc_) catch |err| {
        result.* = null;
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn new_(alloc_: ?*const CAllocator) error{OutOfMemory}!*RenderStateWrapper {
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(RenderStateWrapper) catch
        return error.OutOfMemory;
    ptr.* = .{ .alloc = alloc };
    return ptr;
}

pub fn free(state_: RenderState) callconv(lib.calling_conv) void {
    const state = state_ orelse return;
    const alloc = state.alloc;
    state.state.deinit(alloc);
    alloc.destroy(state);
}

pub fn update(
    state_: RenderState,
    terminal_: terminal_c.Terminal,
) callconv(lib.calling_conv) Result {
    const state = state_ orelse return .invalid_value;
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;

    state.state.update(state.alloc, t) catch return .out_of_memory;
    return .success;
}

pub fn get(
    state_: RenderState,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Data, @intFromEnum(data)) orelse {
            log.warn("render_state_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            state_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

pub fn get_multi(
    state_: RenderState,
    count: usize,
    keys: ?[*]const Data,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = get(state_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn getTyped(
    state_: RenderState,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const state = state_ orelse return .invalid_value;
    switch (data) {
        .invalid => return .invalid_value,
        .cols => out.* = state.state.cols,
        .rows => out.* = state.state.rows,
        .dirty => out.* = state.state.dirty,
        .row_iterator => {
            const it = out.* orelse return .invalid_value;
            const row_data = state.state.row_data.slice();
            it.* = .{
                .alloc = it.alloc,
                .y = null,
                .raws = row_data.items(.raw),
                .cells = row_data.items(.cells),
                .dirty = row_data.items(.dirty),
                .palette = &state.state.colors.palette,
            };
        },
        .color_background => out.* = state.state.colors.background.cval(),
        .color_foreground => out.* = state.state.colors.foreground.cval(),
        .color_cursor => {
            const cursor = state.state.colors.cursor orelse return .invalid_value;
            out.* = cursor.cval();
        },
        .color_cursor_has_value => out.* = state.state.colors.cursor != null,
        .color_palette => out.* = colorpkg.paletteCval(&state.state.colors.palette),
        .cursor_visual_style => out.* = CursorVisualStyle.fromCursorStyle(state.state.cursor.visual_style),
        .cursor_visible => out.* = state.state.cursor.visible,
        .cursor_blinking => out.* = state.state.cursor.blinking,
        .cursor_password_input => out.* = state.state.cursor.password_input,
        .cursor_viewport_has_value => out.* = state.state.cursor.viewport != null,
        .cursor_viewport_x => {
            const vp = state.state.cursor.viewport orelse return .invalid_value;
            out.* = vp.x;
        },
        .cursor_viewport_y => {
            const vp = state.state.cursor.viewport orelse return .invalid_value;
            out.* = vp.y;
        },
        .cursor_viewport_wide_tail => {
            const vp = state.state.cursor.viewport orelse return .invalid_value;
            out.* = vp.wide_tail;
        },
    }

    return .success;
}

pub fn set(
    state_: RenderState,
    option: SetOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(SetOption, @intFromEnum(option)) orelse {
            log.warn("render_state_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| setTyped(
            state_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return .invalid_value)),
        ),
    };
}

fn setTyped(
    state_: RenderState,
    comptime option: SetOption,
    value: *const option.InType(),
) Result {
    const state = state_ orelse return .invalid_value;
    switch (option) {
        .dirty => state.state.dirty = value.*,
    }

    return .success;
}

pub fn colors_get(
    state_: RenderState,
    out_colors_: ?*Colors,
) callconv(lib.calling_conv) Result {
    const state = state_ orelse return .invalid_value;
    const out_colors = out_colors_ orelse return .invalid_value;
    const out_size = out_colors.size;
    if (out_size < @sizeOf(usize)) return .invalid_value;

    const colors = state.state.colors;
    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "background",
    )) {
        out_colors.background = colors.background.cval();
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "foreground",
    )) {
        out_colors.foreground = colors.foreground.cval();
    }

    if (colors.cursor) |cursor| {
        if (lib.structSizedFieldFits(
            Colors,
            out_size,
            "cursor",
        )) {
            out_colors.cursor = cursor.cval();
        }
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "cursor_has_value",
    )) {
        out_colors.cursor_has_value = colors.cursor != null;
    }

    {
        const palette_offset = @offsetOf(Colors, "palette");
        if (out_size > palette_offset) {
            const available = out_size - palette_offset;
            const max_entries = @min(colors.palette.len, available / @sizeOf(colorpkg.RGB.C));
            for (0..max_entries) |i| {
                out_colors.palette[i] = colors.palette[i].cval();
            }
        }
    }

    return .success;
}

pub fn row_iterator_new(
    alloc_: ?*const CAllocator,
    result: *RowIterator,
) callconv(lib.calling_conv) Result {
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(RowIteratorWrapper) catch {
        result.* = null;
        return .out_of_memory;
    };
    ptr.* = .{
        .alloc = alloc,
        .y = undefined,
        .raws = undefined,
        .cells = undefined,
        .dirty = undefined,
        .palette = undefined,
    };
    result.* = ptr;
    return .success;
}

pub fn row_iterator_free(iterator_: RowIterator) callconv(lib.calling_conv) void {
    const iterator = iterator_ orelse return;
    const alloc = iterator.alloc;
    alloc.destroy(iterator);
}

pub fn row_iterator_next(iterator_: RowIterator) callconv(lib.calling_conv) bool {
    const it = iterator_ orelse return false;
    const next_y: size.CellCountInt = if (it.y) |y| y + 1 else 0;
    if (next_y >= it.raws.len) return false;
    it.y = next_y;
    return true;
}

pub fn row_cells_new(
    alloc_: ?*const CAllocator,
    result: *RowCells,
) callconv(lib.calling_conv) Result {
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(RowCellsWrapper) catch {
        result.* = null;
        return .out_of_memory;
    };
    ptr.* = .{
        .alloc = alloc,
        .x = undefined,
        .raws = undefined,
        .graphemes = undefined,
        .styles = undefined,
        .palette = undefined,
    };
    result.* = ptr;
    return .success;
}

pub fn row_cells_next(cells_: RowCells) callconv(lib.calling_conv) bool {
    const cells = cells_ orelse return false;
    const next_x: size.CellCountInt = if (cells.x) |x| x + 1 else 0;
    if (next_x >= cells.raws.len) return false;
    cells.x = next_x;
    return true;
}

pub fn row_cells_select(cells_: RowCells, x: size.CellCountInt) callconv(lib.calling_conv) Result {
    const cells = cells_ orelse return .invalid_value;
    if (x >= cells.raws.len) return .invalid_value;
    cells.x = x;
    return .success;
}

pub fn row_cells_free(cells_: RowCells) callconv(lib.calling_conv) void {
    const cells = cells_ orelse return;
    const alloc = cells.alloc;
    alloc.destroy(cells);
}

/// C: GhosttyRenderStateRowCellsData
pub const RowCellsData = enum(c_int) {
    invalid = 0,
    raw = 1,
    style = 2,
    graphemes_len = 3,
    graphemes_buf = 4,
    bg_color = 5,
    fg_color = 6,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: RowCellsData) type {
        return switch (self) {
            .invalid => void,
            .raw => page.Cell.C,
            .style => style_c.Style,
            .graphemes_len => u32,
            .graphemes_buf => u32,
            .bg_color, .fg_color => colorpkg.RGB.C,
        };
    }
};

pub fn row_cells_get(
    cells_: RowCells,
    data: RowCellsData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(RowCellsData, @intFromEnum(data)) orelse {
            log.warn("render_state_row_cells_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| rowCellsGetTyped(
            cells_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

pub fn row_cells_get_multi(
    cells_: RowCells,
    count: usize,
    keys: ?[*]const RowCellsData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = row_cells_get(cells_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn rowCellsGetTyped(
    cells_: RowCells,
    comptime data: RowCellsData,
    out: *data.OutType(),
) Result {
    const cells = cells_ orelse return .invalid_value;
    const x = cells.x orelse return .invalid_value;
    const cell = cells.raws[x];
    switch (data) {
        .invalid => return .invalid_value,
        .raw => out.* = cell.cval(),
        .style => out.* = if (cell.hasStyling())
            style_c.Style.fromStyle(cells.styles[x])
        else
            style_c.Style.fromStyle(.{}),
        .graphemes_len => {
            if (!cell.hasText()) {
                out.* = 0;
                return .success;
            }
            const extra = if (cell.hasGrapheme()) cells.graphemes[x] else &[_]u21{};
            out.* = @intCast(1 + extra.len);
        },
        .graphemes_buf => {
            if (!cell.hasText()) return .success;
            const extra = if (cell.hasGrapheme()) cells.graphemes[x] else &[_]u21{};
            const buf: [*]u32 = @ptrCast(out);
            buf[0] = cell.codepoint();
            for (extra, 1..) |cp, i| {
                buf[i] = cp;
            }
        },
        .bg_color => {
            const s: Style = if (cell.hasStyling()) cells.styles[x] else .{};
            const bg = s.bg(&cell, cells.palette) orelse return .invalid_value;
            out.* = bg.cval();
        },
        .fg_color => {
            const s: Style = if (cell.hasStyling()) cells.styles[x] else .{};
            if (s.fg_color == .none) return .invalid_value;
            const fg = s.fg(.{ .default = .{}, .palette = cells.palette });
            out.* = fg.cval();
        },
    }

    return .success;
}

/// C: GhosttyRenderStateRowData
pub const RowData = enum(c_int) {
    invalid = 0,
    dirty = 1,
    raw = 2,
    cells = 3,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: RowData) type {
        return switch (self) {
            .invalid => void,
            .dirty => bool,
            .raw => row.CRow,
            .cells => RowCells,
        };
    }
};

/// C: GhosttyRenderStateRowOption
pub const RowOption = enum(c_int) {
    dirty = 0,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: RowOption) type {
        return switch (self) {
            .dirty => bool,
        };
    }
};

pub fn row_get(
    iterator_: RowIterator,
    data: RowData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(RowData, @intFromEnum(data)) orelse {
            log.warn("render_state_row_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| rowGetTyped(
            iterator_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

pub fn row_get_multi(
    iterator_: RowIterator,
    count: usize,
    keys: ?[*]const RowData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = row_get(iterator_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn rowGetTyped(
    iterator_: RowIterator,
    comptime data: RowData,
    out: *data.OutType(),
) Result {
    const it = iterator_ orelse return .invalid_value;
    const y = it.y orelse return .invalid_value;
    switch (data) {
        .invalid => return .invalid_value,
        .dirty => out.* = it.dirty[y],
        .raw => out.* = it.raws[y].cval(),
        .cells => {
            const cells = out.* orelse return .invalid_value;
            const cell_data = it.cells[y].slice();
            cells.* = .{
                .alloc = cells.alloc,
                .x = null,
                .raws = cell_data.items(.raw),
                .graphemes = cell_data.items(.grapheme),
                .styles = cell_data.items(.style),
                .palette = it.palette,
            };
        },
    }

    return .success;
}

pub fn row_set(
    iterator_: RowIterator,
    option: RowOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(RowOption, @intFromEnum(option)) orelse {
            log.warn("render_state_row_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| rowSetTyped(
            iterator_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return .invalid_value)),
        ),
    };
}

fn rowSetTyped(
    iterator_: RowIterator,
    comptime option: RowOption,
    value: *const option.InType(),
) Result {
    const it = iterator_ orelse return .invalid_value;
    const y = it.y orelse return .invalid_value;
    switch (option) {
        .dirty => it.dirty[y] = value.*,
    }

    return .success;
}

test "render: new/free" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    try testing.expect(state != null);
    free(state);
}

test "render: free null" {
    free(null);
}

test "render: update invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, update(null, null));
    try testing.expectEqual(Result.invalid_value, update(state, null));
}

test "render: get invalid value" {
    var cols: size.CellCountInt = 0;
    try testing.expectEqual(Result.invalid_value, get(null, .cols, @ptrCast(&cols)));
}

test "render: get invalid data" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, get(state, .invalid, null));
}

test "render: colors get invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var colors: Colors = std.mem.zeroes(Colors);
    colors.size = @sizeOf(Colors);

    try testing.expectEqual(Result.invalid_value, colors_get(null, &colors));
    try testing.expectEqual(Result.invalid_value, colors_get(state, null));

    colors.size = @sizeOf(usize) - 1;
    try testing.expectEqual(Result.invalid_value, colors_get(state, &colors));
}

test "render: get/set dirty invalid value" {
    var dirty: Dirty = .false;
    try testing.expectEqual(Result.invalid_value, get(null, .dirty, @ptrCast(&dirty)));
    const dirty_full: Dirty = .full;
    try testing.expectEqual(Result.invalid_value, set(null, .dirty, @ptrCast(&dirty_full)));
}

test "render: get/set dirty" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var dirty: Dirty = undefined;
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.false, dirty);

    const dirty_partial: Dirty = .partial;
    try testing.expectEqual(Result.success, set(state, .dirty, @ptrCast(&dirty_partial)));
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.partial, dirty);

    const dirty_full: Dirty = .full;
    try testing.expectEqual(Result.success, set(state, .dirty, @ptrCast(&dirty_full)));
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.full, dirty);
}

test "render: set null value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, set(state, .dirty, null));
}

test "render: row iterator get invalid value" {
    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.invalid_value, get(null, .row_iterator, @ptrCast(&iterator)));
}

test "render: row iterator new/free" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expect(iterator != null);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));

    const iterator_ptr = iterator.?;
    const row_data = state.?.state.row_data.slice();

    try testing.expectEqual(@as(?size.CellCountInt, null), iterator_ptr.y);
    try testing.expectEqual(row_data.items(.raw).len, iterator_ptr.raws.len);
    try testing.expectEqual(row_data.items(.cells).len, iterator_ptr.cells.len);
    try testing.expectEqual(row_data.items(.dirty).len, iterator_ptr.dirty.len);
}

test "render: row iterator free null" {
    row_iterator_free(null);
}

test "render: row iterator next null" {
    try testing.expect(!row_iterator_next(null));
}

test "render: row get null" {
    var dirty: bool = undefined;
    try testing.expectEqual(Result.invalid_value, row_get(null, .dirty, @ptrCast(&dirty)));
}

test "render: row get invalid data" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));
    try testing.expect(row_iterator_next(iterator));
    try testing.expectEqual(Result.invalid_value, row_get(iterator, .invalid, null));
}

test "render: row set null" {
    const dirty = false;
    try testing.expectEqual(Result.invalid_value, row_set(null, .dirty, @ptrCast(&dirty)));
}

test "render: row set before iteration" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));
    const dirty = false;
    try testing.expectEqual(Result.invalid_value, row_set(iterator, .dirty, @ptrCast(&dirty)));
}

test "render: row get before iteration" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));
    var dirty: bool = undefined;
    try testing.expectEqual(Result.invalid_value, row_get(iterator, .dirty, @ptrCast(&dirty)));
}

test "render: row get/set dirty" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    // Dirty the first row so the iterator has at least one dirty row to observe.
    terminal_c.vt_write(terminal, "hello", 5);
    try testing.expectEqual(Result.success, update(state, terminal));

    // Create an iterator and verify it is dirty.
    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));
    var dirty: bool = undefined;
    try testing.expectEqual(Result.success, row_get(it, .dirty, @ptrCast(&dirty)));
    try testing.expect(dirty);

    // Clear dirty on this row.
    const dirty_false = false;
    try testing.expectEqual(Result.success, row_set(it, .dirty, @ptrCast(&dirty_false)));

    // It should not be dirty anymore.
    var it2: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it2,
    ));
    defer row_iterator_free(it2);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it2)));
    try testing.expect(row_iterator_next(it2));
    try testing.expectEqual(Result.success, row_get(it2, .dirty, @ptrCast(&dirty)));
    try testing.expect(!dirty);
}

test "render: row iterator next" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));

    const rows = state.?.state.rows;
    if (rows == 0) {
        try testing.expect(!row_iterator_next(iterator));
        return;
    }

    try testing.expect(row_iterator_next(iterator));
    try testing.expectEqual(@as(?size.CellCountInt, 0), iterator.?.y);

    var i: size.CellCountInt = 1;
    while (i < rows) : (i += 1) {
        try testing.expect(row_iterator_next(iterator));
        try testing.expectEqual(@as(?size.CellCountInt, i), iterator.?.y);
    }

    try testing.expect(!row_iterator_next(iterator));
    try testing.expectEqual(@as(?size.CellCountInt, rows - 1), iterator.?.y);
}

test "render: update" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    terminal_c.vt_write(terminal, "hello", 5);
    try testing.expectEqual(Result.success, update(state, terminal));

    var cols: size.CellCountInt = 0;
    var rows_val: size.CellCountInt = 0;
    try testing.expectEqual(Result.success, get(state, .cols, @ptrCast(&cols)));
    try testing.expectEqual(Result.success, get(state, .rows, @ptrCast(&rows_val)));
    try testing.expectEqual(@as(size.CellCountInt, 80), cols);
    try testing.expectEqual(@as(size.CellCountInt, 24), rows_val);
}

test "render: colors get" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var colors: Colors = std.mem.zeroes(Colors);
    colors.size = @sizeOf(Colors);
    try testing.expectEqual(Result.success, colors_get(state, &colors));

    const state_colors = &state.?.state.colors;
    try testing.expectEqual(state_colors.background.cval(), colors.background);
    try testing.expectEqual(state_colors.foreground.cval(), colors.foreground);

    if (state_colors.cursor) |cursor| {
        try testing.expect(colors.cursor_has_value);
        try testing.expectEqual(cursor.cval(), colors.cursor);
    } else {
        try testing.expect(!colors.cursor_has_value);
    }

    for (state_colors.palette, colors.palette) |expected, actual| {
        try testing.expectEqual(expected.cval(), actual);
    }
}

test "render: row cells bg_color no background" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    // Write plain text (no background color set).
    terminal_c.vt_write(terminal, "hello", 5);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    // No background set, should return invalid_value.
    var bg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.invalid_value, row_cells_get(cells, .bg_color, @ptrCast(&bg)));
}

test "render: row cells bg_color from style" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    // Set an RGB background via SGR 48;2;R;G;B and write text.
    terminal_c.vt_write(terminal, "\x1b[48;2;10;20;30mA", 18);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    var bg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.success, row_cells_get(cells, .bg_color, @ptrCast(&bg)));
    try testing.expectEqual(@as(u8, 10), bg.r);
    try testing.expectEqual(@as(u8, 20), bg.g);
    try testing.expectEqual(@as(u8, 30), bg.b);
}

test "render: row cells bg_color from content tag" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    // Set an RGB background and then erase the line. The erased cells
    // should carry the background color via the content tag (bg_color_rgb)
    // rather than through the style.
    terminal_c.vt_write(terminal, "\x1b[48;2;10;20;30m\x1b[2K", 21);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    var bg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.success, row_cells_get(cells, .bg_color, @ptrCast(&bg)));
    try testing.expectEqual(@as(u8, 10), bg.r);
    try testing.expectEqual(@as(u8, 20), bg.g);
    try testing.expectEqual(@as(u8, 30), bg.b);
}

test "render: row cells fg_color no foreground" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    // Write plain text (no foreground color set).
    terminal_c.vt_write(terminal, "hello", 5);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    // No foreground set, should return invalid_value.
    var fg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.invalid_value, row_cells_get(cells, .fg_color, @ptrCast(&fg)));
}

test "render: row cells fg_color from style" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    // Set an RGB foreground via SGR 38;2;R;G;B and write text.
    terminal_c.vt_write(terminal, "\x1b[38;2;10;20;30mA", 18);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    var fg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.success, row_cells_get(cells, .fg_color, @ptrCast(&fg)));
    try testing.expectEqual(@as(u8, 10), fg.r);
    try testing.expectEqual(@as(u8, 20), fg.g);
    try testing.expectEqual(@as(u8, 30), fg.b);
}

test "render: colors get supports truncated sized struct" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var colors: Colors = std.mem.zeroes(Colors);
    const sentinel: colorpkg.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    for (&colors.palette) |*entry| entry.* = sentinel;

    colors.size = @offsetOf(Colors, "palette") + @sizeOf(colorpkg.RGB.C) * 2;
    try testing.expectEqual(Result.success, colors_get(state, &colors));

    const state_colors = &state.?.state.colors;
    try testing.expectEqual(state_colors.palette[0].cval(), colors.palette[0]);
    try testing.expectEqual(state_colors.palette[1].cval(), colors.palette[1]);
    try testing.expectEqual(sentinel, colors.palette[2]);
}

test "render: get_multi success" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var cols: u16 = 0;
    var rows: u16 = 0;
    var written: usize = 0;

    const keys = [_]Data{ .cols, .rows };
    var values = [_]?*anyopaque{ @ptrCast(&cols), @ptrCast(&rows) };
    try testing.expectEqual(Result.success, get_multi(state, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}

test "render: get_multi null returns invalid_value" {
    var cols: u16 = 0;
    var values = [_]?*anyopaque{@ptrCast(&cols)};
    try testing.expectEqual(Result.invalid_value, get_multi(null, 1, null, &values, null));
}

test "render: row_get_multi success" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var dirty: bool = true;
    var written: usize = 0;

    const keys = [_]RowData{.dirty};
    var values = [_]?*anyopaque{@ptrCast(&dirty)};
    try testing.expectEqual(Result.success, row_get_multi(it, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
}

test "render: row_get_multi null returns invalid_value" {
    var dirty: bool = false;
    var values = [_]?*anyopaque{@ptrCast(&dirty)};
    try testing.expectEqual(Result.invalid_value, row_get_multi(null, 1, null, &values, null));
}

test "render: row_cells_get_multi success" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "A", 1);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    var raw: row.CRow = undefined;
    var written: usize = 0;

    const keys = [_]RowCellsData{.raw};
    var values = [_]?*anyopaque{@ptrCast(&raw)};
    try testing.expectEqual(Result.success, row_cells_get_multi(cells, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
}

test "render: row_cells_get_multi null returns invalid_value" {
    var raw: row.CRow = undefined;
    var values = [_]?*anyopaque{@ptrCast(&raw)};
    try testing.expectEqual(Result.invalid_value, row_cells_get_multi(null, 1, null, &values, null));
}
