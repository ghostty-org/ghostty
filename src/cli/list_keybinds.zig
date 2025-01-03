const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const vaxis = @import("vaxis");
const input = @import("../input.zig");
const tui = @import("tui.zig");
const Binding = input.Binding;

pub const Options = struct {
    /// If `true`, print out the default keybinds instead of the ones configured
    /// in the config file.
    default: bool = false,

    /// If `true`, print out documentation about the action associated with the
    /// keybinds.
    docs: bool = false,

    /// If `true`, print without formatting even if printing to a tty
    plain: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-keybinds` command is used to list all the available keybinds for
/// Ghostty.
///
/// When executed without any arguments this will list the current keybinds
/// loaded by the config file. If no config file is found or there aren't any
/// changes to the keybinds it will print out the default ones configured for
/// Ghostty
///
/// Flags:
///
///   * `--default`: will print out all the default keybinds
///
///   * `--docs`: currently does nothing, intended to print out documentation
///     about the action associated with the keybinds
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

    var config = if (opts.default) try Config.default(alloc) else try Config.load(alloc);
    defer config.deinit();

    const stdout = std.io.getStdOut();

    // Despite being under the posix namespace, this also works on Windows as of zig 0.13.0
    if (tui.can_pretty_print and !opts.plain and std.posix.isatty(stdout.handle)) {
        return prettyPrint(alloc, config.keybind);
    } else {
        try config.keybind.formatEntryDocs(
            configpkg.entryFormatter("keybind", stdout.writer()),
            opts.docs,
        );
    }

    return 0;
}

fn prettyPrint(alloc: Allocator, keybinds: Config.Keybinds) !u8 {
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

    // Get all of our keybinds into a list. We also search for the longest printed keyname so we can
    // align things nicely
    var iter = keybinds.set.bindings.iterator();
    var bindings = std.ArrayList(Binding).init(alloc);
    var widest_key: u16 = 0;
    var buf: [64]u8 = undefined;
    while (iter.next()) |bind| {
        const action = switch (bind.value_ptr.*) {
            .leader => continue, // TODO: support this
            .leaf => |leaf| leaf.action,
        };
        const key = switch (bind.key_ptr.key) {
            .translated => |k| try std.fmt.bufPrint(&buf, "{s}", .{@tagName(k)}),
            .physical => |k| try std.fmt.bufPrint(&buf, "physical:{s}", .{@tagName(k)}),
            .unicode => |c| try std.fmt.bufPrint(&buf, "{u}", .{c}),
        };
        widest_key = @max(widest_key, win.gwidth(key));
        try bindings.append(.{ .trigger = bind.key_ptr.*, .action = action });
    }
    std.mem.sort(Binding, bindings.items, {}, Binding.lessThan);

    // Set up styles for each modifier
    const super_style: vaxis.Style = .{ .fg = .{ .index = 1 } };
    const ctrl_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const alt_style: vaxis.Style = .{ .fg = .{ .index = 3 } };
    const shift_style: vaxis.Style = .{ .fg = .{ .index = 4 } };

    var longest_col: u16 = 0;

    // Print the list
    for (bindings.items) |bind| {
        win.clear();

        var result: vaxis.Window.PrintResult = .{ .col = 0, .row = 0, .overflow = false };
        const trigger = bind.trigger;
        if (trigger.mods.super) {
            result = win.printSegment(.{ .text = "super", .style = super_style }, .{ .col_offset = result.col });
            result = win.printSegment(.{ .text = " + " }, .{ .col_offset = result.col });
        }
        if (trigger.mods.ctrl) {
            result = win.printSegment(.{ .text = "ctrl ", .style = ctrl_style }, .{ .col_offset = result.col });
            result = win.printSegment(.{ .text = " + " }, .{ .col_offset = result.col });
        }
        if (trigger.mods.alt) {
            result = win.printSegment(.{ .text = "alt  ", .style = alt_style }, .{ .col_offset = result.col });
            result = win.printSegment(.{ .text = " + " }, .{ .col_offset = result.col });
        }
        if (trigger.mods.shift) {
            result = win.printSegment(.{ .text = "shift", .style = shift_style }, .{ .col_offset = result.col });
            result = win.printSegment(.{ .text = " + " }, .{ .col_offset = result.col });
        }

        const key = switch (trigger.key) {
            .translated => |k| try std.fmt.allocPrint(alloc, "{s}", .{@tagName(k)}),
            .physical => |k| try std.fmt.allocPrint(alloc, "physical:{s}", .{@tagName(k)}),
            .unicode => |c| try std.fmt.allocPrint(alloc, "{u}", .{c}),
        };
        // We don't track the key print because we index the action off the *widest* key so we get
        // nice alignment no matter what was printed for mods
        _ = win.printSegment(.{ .text = key }, .{ .col_offset = result.col });

        if (longest_col < result.col) longest_col = result.col;

        const action = try std.fmt.allocPrint(alloc, "{}", .{bind.action});
        // If our action has an argument, we print the argument in a different color
        if (std.mem.indexOfScalar(u8, action, ':')) |idx| {
            _ = win.print(&.{
                .{ .text = action[0..idx] },
                .{ .text = action[idx .. idx + 1], .style = .{ .dim = true } },
                .{ .text = action[idx + 1 ..], .style = .{ .fg = .{ .index = 5 } } },
            }, .{ .col_offset = longest_col + widest_key + 2 });
        } else {
            _ = win.printSegment(.{ .text = action }, .{ .col_offset = longest_col + widest_key + 2 });
        }
        try vx.prettyPrint(writer);
    }
    try buf_writer.flush();
    return 0;
}
