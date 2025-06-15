const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.renderer_size);

/// All relevant sizes for a rendered terminal. These are all the sizes that
/// any functionality should need to know about the terminal in order to
/// convert between any coordinate systems.
///
/// See the individual field type documentation for more information on each
/// field. One important note is that any pixel values should already be scaled
/// to the current DPI of the screen. If the DPI changes, the sizes should be
/// recalculated and we expect this to be done by the caller.
pub const Size = struct {
    screen: ScreenSize,
    cell: CellSize,
    padding: Padding,

    /// Return the grid size for this size. The grid size is calculated by
    /// taking the screen size, removing padding, and dividing by the cell
    /// dimensions.
    pub fn grid(self: Size) GridSize {
        return .init(self.screen.subPadding(self.padding), self.cell);
    }

    /// The size of the terminal. This is the same as the screen without
    /// padding.
    pub fn terminal(self: Size) ScreenSize {
        return self.screen.subPadding(self.padding);
    }

    /// Set the padding to be balanced around the grid. The balanced
    /// padding is calculated AFTER the explicit padding is taken
    /// into account.
    pub fn balancePadding(self: *Size, explicit: Padding) void {
        // This ensure grid() does the right thing
        self.padding = explicit;

        // Now we can calculate the balanced padding
        self.padding = .balanced(
            self.screen,
            self.grid(),
            self.cell,
        );
    }
};

/// A coordinate. This is defined as a tagged union to allow for different
/// coordinate systems to be represented.
///
/// A coordinate is only valid within the context of a stable Size value.
/// If any of the sizes in the Size struct change, the coordinate is no
/// longer valid and must be recalculated. A conversion function is provided
/// to migrate to a new Size (which may result in failure).
///
/// The coordinate systems are:
///
///   * surface: (0, 0) is the top-left of the surface (with padding). Negative
///     values are allowed and are off the surface. Likewise, values greater
///     than the surface size are off the surface. Units are pixels.
///
///   * terminal: (0, 0) is the top-left of the terminal grid. This is the
///     same as the surface but with the padding removed. Negative values and
///     values greater than the grid size are allowed and are off the terminal.
///     Units are pixels.
///
///   * grid: (0, 0) is the top-left of the grid. Units are in cells. Negative
///     values are not allowed but values greater than the grid size are
///     possible and are off the grid.
///
pub const Coordinate = union(enum) {
    surface: Surface,
    terminal: Terminal,
    grid: Grid,

    pub const Tag = @typeInfo(Coordinate).@"union".tag_type.?;
    pub const Surface = struct { x: f64, y: f64 };
    pub const Terminal = struct { x: f64, y: f64 };
    pub const Grid = struct { x: GridSize.Unit, y: GridSize.Unit };

    /// Convert a coordinate to a different space within the same Size.
    pub fn convert(self: Coordinate, to: Tag, size: Size) Coordinate {
        // Unlikely fast-path but avoid work.
        if (@as(Tag, self) == to) return self;

        // To avoid the combinatorial explosion of conversion functions, we
        // convert to the surface system first and then reconvert from there.
        const surface = self.convertToSurface(size);

        return switch (to) {
            .surface => .{ .surface = surface },
            .terminal => .{ .terminal = .{
                .x = surface.x - @as(f64, @floatFromInt(size.padding.left)),
                .y = surface.y - @as(f64, @floatFromInt(size.padding.top)),
            } },
            .grid => grid: {
                // Get rid of the padding.
                const term = (Coordinate{ .surface = surface }).convert(
                    .terminal,
                    size,
                ).terminal;

                // We need our grid to clamp
                const grid = size.grid();

                // Calculate the grid position.
                const cell_width: f64 = @as(f64, @floatFromInt(size.cell.width));
                const cell_height: f64 = @as(f64, @floatFromInt(size.cell.height));
                const clamped_x: f64 = @max(0, term.x);
                const clamped_y: f64 = @max(0, term.y);
                const col: GridSize.Unit = @intFromFloat(clamped_x / cell_width);
                const row: GridSize.Unit = @intFromFloat(clamped_y / cell_height);
                const clamped_col: GridSize.Unit = @min(col, grid.columns - 1);
                const clamped_row: GridSize.Unit = @min(row, grid.rows - 1);
                break :grid .{ .grid = .{ .x = clamped_col, .y = clamped_row } };
            },
        };
    }

    /// Convert a coordinate to the surface coordinate system.
    fn convertToSurface(self: Coordinate, size: Size) Surface {
        return switch (self) {
            .surface => |v| v,
            .terminal => |v| .{
                .x = v.x + @as(f64, @floatFromInt(size.padding.left)),
                .y = v.y + @as(f64, @floatFromInt(size.padding.top)),
            },
            .grid => |v| grid: {
                const col: f64 = @floatFromInt(v.x);
                const row: f64 = @floatFromInt(v.y);
                const cell_width: f64 = @floatFromInt(size.cell.width);
                const cell_height: f64 = @floatFromInt(size.cell.height);
                const padding_left: f64 = @floatFromInt(size.padding.left);
                const padding_top: f64 = @floatFromInt(size.padding.top);
                break :grid .{
                    .x = col * cell_width + padding_left,
                    .y = row * cell_height + padding_top,
                };
            },
        };
    }
};

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

    /// Calculates the amount of blank space around the grid. This is possible
    /// when padding isn't balanced.
    ///
    /// The "self" screen size here should be the unpadded screen.
    pub fn blankPadding(self: ScreenSize, padding: Padding, grid: GridSize, cell: CellSize) Padding {
        const grid_width = grid.columns * cell.width;
        const grid_height = grid.rows * cell.height;
        const padded_width = grid_width + (padding.left + padding.right);
        const padded_height = grid_height + (padding.top + padding.bottom);

        // Note these have to use a saturating subtraction to avoid underflow
        // because our padding can cause the padded sizes to be larger than
        // our real screen if the screen is shrunk to a minimal size such
        // as 1x1.
        const leftover_width = self.width -| padded_width;
        const leftover_height = self.height -| padded_height;

        return .{
            .top = 0,
            .bottom = leftover_height,
            .right = leftover_width,
            .left = 0,
        };
    }

    /// Returns true if two sizes are equal.
    pub fn equals(self: ScreenSize, other: ScreenSize) bool {
        return self.width == other.width and self.height == other.height;
    }
};

/// The dimensions of the grid itself, in rows/columns units.
pub const GridSize = struct {
    pub const Unit = terminal.size.CellCountInt;

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

test "coordinate conversion" {
    const testing = std.testing;

    // A size for testing purposes. Purposely easy to calculate numbers.
    const test_size: Size = .{
        .screen = .{
            .width = 100,
            .height = 100,
        },

        .cell = .{
            .width = 5,
            .height = 10,
        },

        .padding = .{},
    };

    // Each pair is a test case of [expected, actual]. We only test
    // one-way conversion because conversion can be lossy due to clamping
    // and so on.
    const table: []const [2]Coordinate = &.{
        .{
            .{ .grid = .{ .x = 0, .y = 0 } },
            .{ .surface = .{ .x = 0, .y = 0 } },
        },
        .{
            .{ .grid = .{ .x = 1, .y = 0 } },
            .{ .surface = .{ .x = 6, .y = 0 } },
        },
        .{
            .{ .grid = .{ .x = 1, .y = 1 } },
            .{ .surface = .{ .x = 6, .y = 10 } },
        },
        .{
            .{ .grid = .{ .x = 0, .y = 0 } },
            .{ .surface = .{ .x = -10, .y = -10 } },
        },
        .{
            .{ .grid = .{ .x = test_size.grid().columns - 1, .y = test_size.grid().rows - 1 } },
            .{ .surface = .{ .x = 100_000, .y = 100_000 } },
        },
    };

    for (table) |pair| {
        const expected = pair[0];
        const actual = pair[1].convert(@as(Coordinate.Tag, expected), test_size);
        try testing.expectEqual(expected, actual);
    }
}
