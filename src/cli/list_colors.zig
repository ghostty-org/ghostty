const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const x11_color = @import("../terminal/main.zig").x11_color;
const vaxis = @import("vaxis");
const tui = @import("tui.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// If `true`, print without formatting even if printing to a tty
    plain: bool = false,

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-colors` command is used to list all the named RGB colors in
/// Ghostty.
///
/// Flags:
///
///   * `--plain`: will disable formatting and make the output more
///     friendly for Unix tooling. This is default when not printing to a tty.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut();

    var keys = std.ArrayList([]const u8).init(alloc);
    defer keys.deinit();
    for (x11_color.map.keys()) |key| try keys.append(key);

    std.mem.sortUnstable([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
        }
    }.lessThan);

    // Despite being under the posix namespace, this also works on Windows as of zig 0.13.0
    if (tui.can_pretty_print and !opts.plain and std.posix.isatty(stdout.handle)) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        return prettyPrint(arena.allocator(), keys.items);
    } else {
        const writer = stdout.writer();
        for (keys.items) |name| {
            const rgb = x11_color.map.get(name).?;
            try writer.print("{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{
                name,
                rgb.r,
                rgb.g,
                rgb.b,
            });
        }
    }

    return 0;
}

fn prettyPrint(alloc: Allocator, keys: [][]const u8) !u8 {
    // Set up vaxis
    var tty = try vaxis.Tty.init();
    defer tty.deinit();
    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    // We know we are ghostty, so let's enable mode 2027. Vaxis normally does this but you need an
    // event loop to auto-enable it.
    vx.caps.unicode = .unicode;
    try tty.anyWriter().writeAll(vaxis.ctlseqs.unicode_set);
    defer tty.anyWriter().writeAll(vaxis.ctlseqs.unicode_reset) catch {};

    var buf_writer = tty.bufferedWriter();
    const writer = buf_writer.writer().any();

    const winsize: vaxis.Winsize = switch (builtin.os.tag) {
        // We use some default, it doesn't really matter for what
        // we're doing because we don't do any wrapping.
        .windows => .{
            .rows = 24,
            .cols = 120,
            .x_pixel = 1024,
            .y_pixel = 768,
        },

        else => try vaxis.Tty.getWinsize(tty.fd),
    };
    try vx.resize(alloc, tty.anyWriter(), winsize);

    const win = vx.window();

    var max_name_len: usize = 0;
    for (keys) |name| {
        if (name.len > max_name_len) max_name_len = name.len;
    }

    // max name length plus " = #RRGGBB XX" plus "  " gutter between columns
    const column_size = max_name_len + 15;
    // add two to take into account lack of gutter after last column
    const columns: usize = @divFloor(win.width + 2, column_size);

    var i: usize = 0;
    const step = @divFloor(keys.len, columns) + 1;
    while (i < step) : (i += 1) {
        win.clear();

        var result: vaxis.Window.PrintResult = .{ .col = 0, .row = 0, .overflow = false };

        for (0..columns) |j| {
            const k = i + (step * j);
            if (k >= keys.len) continue;

            const name = keys[k];
            const rgb = x11_color.map.get(name).?;

            const style1: vaxis.Style = .{
                .fg = .{
                    .rgb = .{ rgb.r, rgb.g, rgb.b },
                },
            };
            const style2: vaxis.Style = .{
                .fg = .{
                    .rgb = .{ rgb.r, rgb.g, rgb.b },
                },
                .bg = .{
                    .rgb = .{ rgb.r, rgb.g, rgb.b },
                },
            };

            // name of the color
            result = win.printSegment(
                .{ .text = name },
                .{ .col_offset = result.col },
            );
            // push the color data to the end of the column
            for (0..max_name_len - name.len) |_| {
                result = win.printSegment(
                    .{ .text = " " },
                    .{ .col_offset = result.col },
                );
            }
            result = win.printSegment(
                .{ .text = " = " },
                .{ .col_offset = result.col },
            );
            // rgb triple
            result = win.printSegment(.{
                .text = try std.fmt.allocPrint(
                    alloc,
                    "#{x:0>2}{x:0>2}{x:0>2}",
                    .{
                        rgb.r, rgb.g, rgb.b,
                    },
                ),
                .style = style1,
            }, .{ .col_offset = result.col });
            result = win.printSegment(
                .{ .text = " " },
                .{ .col_offset = result.col },
            );
            // colored block
            result = win.printSegment(
                .{
                    .text = "  ",
                    .style = style2,
                },
                .{ .col_offset = result.col },
            );
            // add the gutter if needed
            if (j + 1 < columns) {
                result = win.printSegment(
                    .{
                        .text = "  ",
                    },
                    .{ .col_offset = result.col },
                );
            }
        }

        // clear the rest of the line
        while (result.col != 0) {
            result = win.printSegment(
                .{
                    .text = " ",
                },
                .{ .col_offset = result.col },
            );
        }

        // output the data
        try vx.prettyPrint(writer);
    }

    // be sure to flush!
    try buf_writer.flush();

    return 0;
}
