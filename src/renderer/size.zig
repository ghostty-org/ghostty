const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.renderer_size);

/// The dimensions of a single "cell" in the terminal grid.
///
/// The dimensions are dependent on the current loaded set of font glyphs.
/// We calculate the width based on the widest character and the height based
/// on the height requirement for an underscore (the "lowest" -- visually --
/// character).
///
/// The units for the width and height are in world space. They have to
/// be normalized for any renderer implementation.
pub const CellSize = struct {
    width: u32,
    height: u32,

    /// Initialize the cell size information from a font group. This ensures
    /// that all renderers use the same cell sizing information for the same
    /// fonts.
    pub fn init(alloc: Allocator, group: *font.GroupCache) !CellSize {
        // Get our cell metrics based on a regular font ascii 'M'. Why 'M'?
        // Doesn't matter, any normal ASCII will do we're just trying to make
        // sure we use the regular font.
        const metrics = metrics: {
            const index = (try group.indexForCodepoint(alloc, 'M', .regular, .text)).?;
            const face = try group.group.faceFromIndex(index);
            break :metrics face.metrics;
        };
        log.debug("cell dimensions={}", .{metrics});

        return CellSize{
            .width = metrics.cell_width,
            .height = metrics.cell_height,
        };
    }
};

/// The dimensions of the screen that the grid is rendered to. This is the
/// terminal screen, so it is likely a subset of the window size. The dimensions
/// should be in pixels.
pub const ScreenSize = struct {
    width: u32,
    height: u32,

    /// Subtract padding from the screen size.
    pub fn subPadding(self: ScreenSize, padding: Padding) ScreenSize {
        return .{
            .width = self.width -| (padding.left + padding.right),
            .height = self.height -| (padding.top + padding.bottom),
        };
    }

    /// Returns true if two sizes are equal.
    pub fn equals(self: ScreenSize, other: ScreenSize) bool {
        return self.width == other.width and self.height == other.height;
    }
};

/// The dimensions of the grid itself, in rows/columns units.
pub const GridSize = struct {
    const Unit = terminal.size.CellCountInt;

    columns: Unit = 0,
    rows: Unit = 0,

    /// Initialize a grid size based on a screen and cell size.
    pub fn init(screen: ScreenSize, cell: CellSize) GridSize {
        var result: GridSize = undefined;
        result.update(screen, cell);
        return result;
    }

    /// Update the columns/rows for the grid based on the given screen and
    /// cell size.
    pub fn update(self: *GridSize, screen: ScreenSize, cell: CellSize) void {
        const cell_width: f32 = @floatFromInt(cell.width);
        const cell_height: f32 = @floatFromInt(cell.height);
        const screen_width: f32 = @floatFromInt(screen.width);
        const screen_height: f32 = @floatFromInt(screen.height);
        const calc_cols: Unit = @intFromFloat(screen_width / cell_width);
        const calc_rows: Unit = @intFromFloat(screen_height / cell_height);
        self.columns = @max(1, calc_cols);
        self.rows = @max(1, calc_rows);
    }

    /// Returns true if two sizes are equal.
    pub fn equals(self: GridSize, other: GridSize) bool {
        return self.columns == other.columns and self.rows == other.rows;
    }
};

/// The padding to add to a screen.
pub const Padding = struct {
    top: u32 = 0,
    bottom: u32 = 0,
    right: u32 = 0,
    left: u32 = 0,

    /// Returns padding that balances the whitespace around the screen
    /// for the given grid and cell sizes.
    pub fn balanced(screen: ScreenSize, grid: GridSize, cell: CellSize) Padding {
        // Turn our cell sizes into floats for the math
        const cell_width: f32 = @floatFromInt(cell.width);
        const cell_height: f32 = @floatFromInt(cell.height);

        // The size of our full grid
        const grid_width = @as(f32, @floatFromInt(grid.columns)) * cell_width;
        const grid_height = @as(f32, @floatFromInt(grid.rows)) * cell_height;

        // The empty space to the right of a line and bottom of the last row
        const space_right = @as(f32, @floatFromInt(screen.width)) - grid_width;
        const space_bot = @as(f32, @floatFromInt(screen.height)) - grid_height;

        // The left/right padding is just an equal split.
        const padding_right = @floor(space_right / 2);
        const padding_left = padding_right;

        // The top/bottom padding is interesting. Subjectively, lots of padding
        // at the top looks bad. So instead of always being equal (like left/right),
        // we force the top padding to be at most equal to the left, and the bottom
        // padding is the difference thereafter.
        const padding_top = @min(padding_left, @floor(space_bot / 2));
        const padding_bot = space_bot - padding_top;

        const zero = @as(f32, 0);
        return .{
            .top = @intFromFloat(@max(zero, padding_top)),
            .bottom = @intFromFloat(@max(zero, padding_bot)),
            .right = @intFromFloat(@max(zero, padding_right)),
            .left = @intFromFloat(@max(zero, padding_left)),
        };
    }

    /// Add another padding to this one
    pub fn add(self: Padding, other: Padding) Padding {
        return .{
            .top = self.top + other.top,
            .bottom = self.bottom + other.bottom,
            .right = self.right + other.right,
            .left = self.left + other.left,
        };
    }

    /// Equality test between two paddings.
    pub fn eql(self: Padding, other: Padding) bool {
        return self.top == other.top and
            self.bottom == other.bottom and
            self.right == other.right and
            self.left == other.left;
    }
};

test "Padding balanced on zero" {
    // On some systems, our screen can be zero-sized for a bit, and we
    // don't want to end up with negative padding.
    const testing = std.testing;
    const grid: GridSize = .{ .columns = 100, .rows = 37 };
    const cell: CellSize = .{ .width = 10, .height = 20 };
    const screen: ScreenSize = .{ .width = 0, .height = 0 };
    const padding = Padding.balanced(screen, grid, cell);
    try testing.expectEqual(Padding{}, padding);
}

test "GridSize update exact" {
    const testing = std.testing;

    var grid: GridSize = .{};
    grid.update(.{
        .width = 100,
        .height = 40,
    }, .{
        .width = 5,
        .height = 10,
    });

    try testing.expectEqual(@as(GridSize.Unit, 20), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 4), grid.rows);
}

test "GridSize update rounding" {
    const testing = std.testing;

    var grid: GridSize = .{};
    grid.update(.{
        .width = 20,
        .height = 40,
    }, .{
        .width = 6,
        .height = 15,
    });

    try testing.expectEqual(@as(GridSize.Unit, 3), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 2), grid.rows);
}
