const std = @import("std");
const testing = std.testing;
const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const renderer_size = @import("../renderer/size.zig");
const point = @import("../terminal/point.zig");
const key = @import("key.zig");
const mouse = @import("mouse.zig");

const log = std.log.scoped(.mouse_encode);

/// Options that affect mouse encoding behavior and provide runtime context.
pub const Options = struct {
    /// Terminal mouse reporting mode (X10, normal, button, any).
    event: terminal.MouseEvent = .none,

    /// Terminal mouse reporting format.
    format: terminal.MouseFormat = .x10,

    /// Full renderer size used to convert surface-space pixel positions
    /// into grid cell coordinates (for most formats) and terminal-space
    /// pixel coordinates (for SGR-Pixels), as well as to determine
    /// whether a position falls outside the visible viewport.
    size: renderer_size.Size,

    /// Whether any mouse button is currently pressed. When a motion
    /// event occurs outside the viewport, it is only reported if a
    /// button is held down and the event mode supports motion tracking.
    /// Without this, out-of-viewport motions are silently dropped.
    ///
    /// This should reflect the state of the current event as well, so
    /// if the encoded event is a button press, this should be true.
    any_button_pressed: bool = false,

    /// Last reported viewport cell for motion deduplication.
    /// If null, motion deduplication state is not tracked.
    last_cell: ?*?point.Coordinate = null,

    /// Initialize from terminal and renderer state. The caller may still
    /// set any_button_pressed and last_cell on the returned value.
    pub fn fromTerminal(
        t: *const Terminal,
        size: renderer_size.Size,
    ) Options {
        return .{
            .event = t.flags.mouse_event,
            .format = t.flags.mouse_format,
            .size = size,
        };
    }
};

/// A normalized mouse event for protocol encoding.
pub const Event = struct {
    /// The action of this mouse event.
    action: mouse.Action = .press,

    /// The button involved in this event. This can be null in the
    /// case of a motion action with no pressed buttons.
    button: ?mouse.Button = null,

    /// Keyboard modifiers held during this event.
    mods: key.Mods = .{},

    /// Mouse position in terminal-space pixels, with (0, 0) at the top-left
    /// of the terminal. Negative values are allowed and indicate positions
    /// above or to the left of the terminal. Values larger than the terminal
    /// size are also allowed and indicate right or below the terminal.
    pos: Pos = .{},

    /// Mouse position in surface-space pixels.
    pub const Pos = extern struct {
        x: f32 = 0,
        y: f32 = 0,
    };
};

/// Encode the mouse event to the writer according to the options.
///
/// Not all events result in output.
pub fn encode(
    writer: *std.Io.Writer,
    event: Event,
    opts: Options,
) std.Io.Writer.Error!void {
    if (!shouldReport(event, opts)) return;

    // Handle scenarios where the mouse position is outside the viewport.
    // We always report release events no matter where they happen.
    if (event.action != .release and
        posOutOfViewport(event.pos, opts.size))
    {
        // If we don't have a motion-tracking event mode, do nothing,
        // because events outside the viewport are never reported in
        // such cases.
        if (!terminal.mouse.eventSendsMotion(opts.event)) return;

        // For motion modes, we only report if a button is currently pressed.
        // This lets a TUI detect a click over the surface + drag out
        // of the surface.
        if (!opts.any_button_pressed) return;
    }

    const cell = posToCell(event.pos, opts.size);

    // We only send motion events when the cell changed unless
    // we're tracking raw pixels.
    if (event.action == .motion and opts.format != .sgr_pixels) {
        if (opts.last_cell) |last| {
            if (last.*) |last_cell| {
                if (last_cell.eql(cell)) return;
            }
        }
    }

    // Update the last reported cell if we are tracking it.
    if (opts.last_cell) |last| last.* = cell;

    const button_code = buttonCode(event, opts) orelse return;
    switch (opts.format) {
        .x10 => {
            if (cell.x > 222 or cell.y > 222) {
                log.info("X10 mouse format can only encode X/Y up to 223", .{});
                return;
            }

            // + 1 because our x/y are zero-indexed and the protocol uses 1-indexing.
            try writer.writeAll("\x1B[M");
            try writer.writeByte(32 + button_code);
            try writer.writeByte(32 + @as(u8, @intCast(cell.x)) + 1);
            try writer.writeByte(32 + @as(u8, @intCast(cell.y)) + 1);
        },

        .utf8 => {
            try writer.writeAll("\x1B[M");

            // The button code always fits in a single byte.
            try writer.writeByte(32 + button_code);

            var buf: [4]u8 = undefined;
            const x_cp: u21 = @intCast(@as(u32, cell.x) + 33);
            const y_cp: u21 = @intCast(cell.y + 33);

            const x_len = std.unicode.utf8Encode(x_cp, &buf) catch unreachable;
            try writer.writeAll(buf[0..x_len]);

            const y_len = std.unicode.utf8Encode(y_cp, &buf) catch unreachable;
            try writer.writeAll(buf[0..y_len]);
        },

        .sgr => try writer.print("\x1B[<{d};{d};{d}{c}", .{
            button_code,
            cell.x + 1,
            cell.y + 1,
            @as(u8, if (event.action == .release) 'm' else 'M'),
        }),

        .urxvt => try writer.print("\x1B[{d};{d};{d}M", .{
            32 + button_code,
            cell.x + 1,
            cell.y + 1,
        }),

        .sgr_pixels => {
            const pixels = posToPixels(event.pos, opts.size);
            try writer.print("\x1B[<{d};{d};{d}{c}", .{
                button_code,
                pixels.x,
                pixels.y,
                @as(u8, if (event.action == .release) 'm' else 'M'),
            });
        },
    }
}

/// Returns true if this event should be reported for the given mouse
/// event mode.
fn shouldReport(event: Event, opts: Options) bool {
    return switch (opts.event) {
        .none => false,

        // X10 only reports button presses of left, middle, and right.
        .x10 => event.action == .press and
            event.button != null and
            (event.button.? == .left or
                event.button.? == .middle or
                event.button.? == .right),

        // Normal mode does not report motion.
        .normal => event.action != .motion,

        // Button mode requires an active button for motion events.
        .button => event.button != null,

        // Any mode reports everything.
        .any => true,
    };
}

fn buttonCode(event: Event, opts: Options) ?u8 {
    var acc: u8 = code: {
        if (event.button == null) {
            // Null button means motion with no pressed button.
            break :code 3;
        }

        if (event.action == .release and
            opts.format != .sgr and
            opts.format != .sgr_pixels)
        {
            // Legacy releases are always encoded as button 3.
            break :code 3;
        }

        break :code switch (event.button.?) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .four => 64,
            .five => 65,
            .six => 66,
            .seven => 67,
            .eight => 128,
            .nine => 129,
            else => return null,
        };
    };

    // X10 does not include modifiers.
    if (opts.event != .x10) {
        if (event.mods.shift) acc += 4;
        if (event.mods.alt) acc += 8;
        if (event.mods.ctrl) acc += 16;
    }

    // Motion adds another bit.
    if (event.action == .motion) acc += 32;

    return acc;
}

/// Terminal-space pixel position for SGR pixel reporting.
const PixelPoint = struct {
    x: i32,
    y: i32,
};

/// Returns true if the surface-space pixel position is outside the
/// visible viewport bounds (negative or beyond screen dimensions).
fn posOutOfViewport(pos: Event.Pos, size: renderer_size.Size) bool {
    const max_x: f32 = @floatFromInt(size.screen.width);
    const max_y: f32 = @floatFromInt(size.screen.height);
    return pos.x < 0 or pos.y < 0 or pos.x > max_x or pos.y > max_y;
}

/// Converts a surface-space pixel position to a zero-based grid cell
/// coordinate (column, row) within the terminal viewport. Out-of-bounds
/// values are clamped to the valid grid range (0 to columns/rows - 1).
fn posToCell(pos: Event.Pos, size: renderer_size.Size) point.Coordinate {
    const coord: renderer_size.Coordinate = .{ .surface = .{
        .x = @as(f64, @floatCast(pos.x)),
        .y = @as(f64, @floatCast(pos.y)),
    } };
    const grid = coord.convert(.grid, size).grid;
    return .{ .x = grid.x, .y = grid.y };
}

/// Converts a surface-space pixel position to terminal-space pixel
/// coordinates (accounting for padding/scaling) used by SGR-Pixels mode.
/// Unlike grid conversion, terminal-space coordinates are not clamped
/// and may be negative or exceed the terminal dimensions.
fn posToPixels(pos: Event.Pos, size: renderer_size.Size) PixelPoint {
    const coord: renderer_size.Coordinate.Terminal = (renderer_size.Coordinate{ .surface = .{
        .x = @as(f64, @floatCast(pos.x)),
        .y = @as(f64, @floatCast(pos.y)),
    } }).convert(.terminal, size).terminal;

    return .{
        .x = @as(i32, @intFromFloat(@round(coord.x))),
        .y = @as(i32, @intFromFloat(@round(coord.y))),
    };
}

fn testSize() renderer_size.Size {
    return .{
        .screen = .{ .width = 1_000, .height = 1_000 },
        .cell = .{ .width = 1, .height = 1 },
        .padding = .{},
    };
}

test "shouldReport: none mode never reports" {
    const size = testSize();
    inline for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        try testing.expect(!shouldReport(.{
            .button = .left,
            .action = action,
        }, .{ .event = .none, .size = size }));
    }
}

test "shouldReport: x10 reports only left/middle/right press" {
    const size = testSize();
    // Left, middle, right presses should report.
    inline for ([_]mouse.Button{ .left, .middle, .right }) |btn| {
        try testing.expect(shouldReport(.{
            .button = btn,
            .action = .press,
        }, .{ .event = .x10, .size = size }));
    }

    // Release is not reported.
    try testing.expect(!shouldReport(.{
        .button = .left,
        .action = .release,
    }, .{ .event = .x10, .size = size }));

    // Motion is not reported.
    try testing.expect(!shouldReport(.{
        .button = .left,
        .action = .motion,
    }, .{ .event = .x10, .size = size }));

    // Other buttons are not reported.
    try testing.expect(!shouldReport(.{
        .button = .four,
        .action = .press,
    }, .{ .event = .x10, .size = size }));

    // Null button is not reported.
    try testing.expect(!shouldReport(.{
        .button = null,
        .action = .press,
    }, .{ .event = .x10, .size = size }));
}

test "shouldReport: normal reports press and release but not motion" {
    const size = testSize();
    try testing.expect(shouldReport(.{
        .button = .left,
        .action = .press,
    }, .{ .event = .normal, .size = size }));

    try testing.expect(shouldReport(.{
        .button = .left,
        .action = .release,
    }, .{ .event = .normal, .size = size }));

    try testing.expect(!shouldReport(.{
        .button = .left,
        .action = .motion,
    }, .{ .event = .normal, .size = size }));
}

test "shouldReport: button mode requires a button" {
    const size = testSize();
    // With a button, all actions report.
    inline for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        try testing.expect(shouldReport(.{
            .button = .left,
            .action = action,
        }, .{ .event = .button, .size = size }));
    }

    // Without a button (null), nothing reports.
    inline for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        try testing.expect(!shouldReport(.{
            .button = null,
            .action = action,
        }, .{ .event = .button, .size = size }));
    }
}

test "shouldReport: any mode reports everything" {
    const size = testSize();
    inline for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        try testing.expect(shouldReport(.{
            .button = .left,
            .action = action,
        }, .{ .event = .any, .size = size }));
    }

    // Even null button + motion reports.
    try testing.expect(shouldReport(.{
        .button = null,
        .action = .motion,
    }, .{ .event = .any, .size = size }));
}

test "x10 press left" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .mods = .{ .shift = true, .alt = true, .ctrl = true },
        .pos = .{ .x = 0, .y = 0 },
    }, .{
        .event = .x10,
        .format = .x10,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualSlices(u8, &.{
        0x1B,
        '[',
        'M',
        32,
        33,
        33,
    }, writer.buffered());
}

test "x10 ignores release" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .release,
    }, .{
        .event = .x10,
        .format = .x10,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "normal ignores motion" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .motion,
    }, .{
        .event = .normal,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "button mode requires button" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = null,
        .action = .motion,
    }, .{
        .event = .button,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "sgr release keeps button identity" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .right,
        .action = .release,
        .pos = .{ .x = 4, .y = 5 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<2;5;6m", writer.buffered());
}

test "sgr motion with no button" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = null,
        .action = .motion,
        .pos = .{ .x = 1, .y = 2 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<35;2;3M", writer.buffered());
}

test "urxvt with modifiers" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .mods = .{ .shift = true, .alt = true, .ctrl = true },
        .pos = .{ .x = 2, .y = 3 },
    }, .{
        .event = .any,
        .format = .urxvt,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[60;3;4M", writer.buffered());
}

test "utf8 encodes large coordinates" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .pos = .{ .x = 300, .y = 400 },
    }, .{
        .event = .any,
        .format = .utf8,
        .size = testSize(),
        .last_cell = &last,
    });

    const out = writer.buffered();
    try testing.expectEqualSlices(u8, &.{ 0x1B, '[', 'M', 32 }, out[0..4]);

    const view = try std.unicode.Utf8View.init(out[4..]);
    var it = view.iterator();
    try testing.expectEqual(@as(u21, 333), it.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 433), it.nextCodepoint().?);
    try testing.expectEqual(@as(?u21, null), it.nextCodepoint());
}

test "x10 coordinate limit" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .pos = .{ .x = 223, .y = 0 },
    }, .{
        .event = .x10,
        .format = .x10,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "sgr wheel button mappings" {
    const Case = struct {
        button: mouse.Button,
        code: u8,
    };

    inline for ([_]Case{
        .{ .button = .four, .code = 64 },
        .{ .button = .five, .code = 65 },
        .{ .button = .six, .code = 66 },
        .{ .button = .seven, .code = 67 },
    }) |c| {
        var data: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        var last: ?point.Coordinate = null;
        try encode(&writer, .{
            .button = c.button,
            .action = .press,
            .pos = .{ .x = 0, .y = 0 },
        }, .{
            .event = .any,
            .format = .sgr,
            .size = testSize(),
            .last_cell = &last,
        });

        var expected: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&expected, "\x1B[<{d};1;1M", .{c.code});
        try testing.expectEqualStrings(want, writer.buffered());
    }
}

test "urxvt release uses legacy button 3 encoding" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .right,
        .action = .release,
        .pos = .{ .x = 2, .y = 3 },
    }, .{
        .event = .any,
        .format = .urxvt,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[35;3;4M", writer.buffered());
}

test "unsupported button is ignored" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .ten,
        .action = .press,
        .pos = .{ .x = 1, .y = 1 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "sgr pixels uses terminal-space cursor coordinates" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .pos = .{ .x = 10, .y = 20 },
    }, .{
        .event = .any,
        .format = .sgr_pixels,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<0;10;20M", writer.buffered());
}

test "sgr pixels release keeps button identity" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .right,
        .action = .release,
        .pos = .{ .x = 10, .y = 20 },
    }, .{
        .event = .any,
        .format = .sgr_pixels,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<2;10;20m", writer.buffered());
}

test "position exactly at viewport boundary is encoded in final cell" {
    const size: renderer_size.Size = .{
        .screen = .{ .width = 10, .height = 10 },
        .cell = .{ .width = 2, .height = 2 },
        .padding = .{},
    };

    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .pos = .{ .x = 10, .y = 10 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = size,
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<0;5;5M", writer.buffered());
}

test "outside viewport motion with no pressed button is ignored" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .motion,
        .pos = .{ .x = -1, .y = -1 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .any_button_pressed = false,
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "outside viewport motion with pressed button is reported" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .motion,
        .pos = .{ .x = -1, .y = -1 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .any_button_pressed = true,
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<32;1;1M", writer.buffered());
}

test "motion is deduped by last cell except sgr pixels" {
    var last: ?point.Coordinate = null;

    {
        var data: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        try encode(&writer, .{
            .button = .left,
            .action = .motion,
            .pos = .{ .x = 5, .y = 6 },
        }, .{
            .event = .any,
            .format = .sgr,
            .size = testSize(),
            .last_cell = &last,
        });
        try testing.expect(writer.buffered().len > 0);
    }

    {
        var data: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        try encode(&writer, .{
            .button = .left,
            .action = .motion,
            .pos = .{ .x = 5, .y = 6 },
        }, .{
            .event = .any,
            .format = .sgr,
            .size = testSize(),
            .last_cell = &last,
        });
        try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }

    {
        var data: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        try encode(&writer, .{
            .button = .left,
            .action = .motion,
            .pos = .{ .x = 5, .y = 6 },
        }, .{
            .event = .any,
            .format = .sgr_pixels,
            .size = testSize(),
            .last_cell = &last,
        });
        try testing.expect(writer.buffered().len > 0);
    }
}
