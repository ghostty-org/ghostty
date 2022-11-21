const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const inputpkg = @import("input.zig");
const passwd = @import("passwd.zig");
const terminal = @import("terminal/main.zig");

const log = std.log.scoped(.config);

/// Used on Unixes for some defaults.
const c = @cImport({
    @cInclude("unistd.h");
});

/// Config is the main config struct. These fields map directly to the
/// CLI flag names hence we use a lot of `@""` syntax to support hyphens.
pub const Config = struct {
    /// The font families to use.
    @"font-family": ?[:0]const u8 = null,
    @"font-family-bold": ?[:0]const u8 = null,
    @"font-family-italic": ?[:0]const u8 = null,
    @"font-family-bold-italic": ?[:0]const u8 = null,

    /// Font size in points
    @"font-size": u8 = switch (builtin.os.tag) {
        // On Mac we default a little bigger since this tends to look better.
        // This is purely subjective but this is easy to modify.
        .macos => 13,
        else => 12,
    },

    /// Background color for the window.
    background: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 },

    /// Foreground color for the window.
    foreground: Color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },

    /// The foreground and background color for selection. If this is not
    /// set, then the selection color is just the inverted window background
    /// and foreground (note: not to be confused with the cell bg/fg).
    @"selection-foreground": ?Color = null,
    @"selection-background": ?Color = null,

    /// Color palette for the 256 color form that many terminal applications
    /// use. The syntax of this configuration is "N=HEXCODE" where "n"
    /// is 0 to 255 (for the 256 colors) and HEXCODE is a typical RGB
    /// color code such as "#AABBCC". The 0 to 255 correspond to the
    /// terminal color table.
    ///
    /// For definitions on all the codes:
    /// https://www.ditig.com/256-colors-cheat-sheet
    palette: Palette = .{},

    /// The color of the cursor. If this is not set, a default will be chosen.
    @"cursor-color": ?Color = null,

    /// The command to run, usually a shell. If this is not an absolute path,
    /// it'll be looked up in the PATH. If this is not set, a default will
    /// be looked up from your system. The rules for the default lookup are:
    ///
    ///   - SHELL environment variable
    ///   - passwd entry (user information)
    ///
    command: ?[]const u8 = null,

    /// The directory to change to after starting the command.
    ///
    /// The default is "inherit" except in special scenarios listed next.
    /// If ghostty can detect it is launched on macOS from launchd
    /// (double-clicked), then it defaults to "home".
    ///
    /// The value of this must be an absolute value or one of the special
    /// values below:
    ///
    ///   - "home" - The home directory of the executing user.
    ///   - "inherit" - The working directory of the launching process.
    ///
    @"working-directory": ?[]const u8 = null,

    /// Key bindings. The format is "trigger=action". Duplicate triggers
    /// will overwrite previously set values.
    ///
    /// Trigger: "+"-separated list of keys and modifiers. Example:
    /// "ctrl+a", "ctrl+shift+b", "up". Some notes:
    ///
    ///   - modifiers cannot repeat, "ctrl+ctrl+a" is invalid.
    ///   - modifers and key scan be in any order, "shift+a+ctrl" is weird,
    ///     but valid.
    ///   - only a single key input is allowed, "ctrl+a+b" is invalid.
    ///
    /// Action is the action to take when the trigger is satisfied. It takes
    /// the format "action" or "action:param". The latter form is only valid
    /// if the action requires a parameter.
    ///
    ///   - "ignore" - Do nothing, ignore the key input. This can be used to
    ///     black hole certain inputs to have no effect.
    ///   - "unbind" - Remove the binding. This makes it so the previous action
    ///     is removed, and the key will be sent through to the child command
    ///     if it is printable.
    ///   - "csi:text" - Send a CSI sequence. i.e. "csi:A" sends "cursor up".
    ///
    /// Some notes for the action:
    ///
    ///   - The parameter is taken as-is after the ":". Double quotes or
    ///     other mechanisms are included and NOT parsed. If you want to
    ///     send a string value that includes spaces, wrap the entire
    ///     trigger/action in double quotes. Example: --keybind="up=csi:A B"
    ///
    keybind: Keybinds = .{},

    /// Window padding. This applies padding between the terminal cells and
    /// the window border. The "x" option applies to the left and right
    /// padding and the "y" option is top and bottom. The value is in points,
    /// meaning that it will be scaled appropriately for screen DPI.
    ///
    /// If this value is set too large, the screen will render nothing, because
    /// the grid will be completely squished by the padding. It is up to you
    /// as the user to pick a reasonable value. If you pick an unreasonable
    /// value, a warning will appear in the logs.
    @"window-padding-x": u32 = 0,
    @"window-padding-y": u32 = 0,

    /// The viewport dimensions are usually not perfectly divisible by
    /// the cell size. In this case, some extra padding on the end of a
    /// column and the bottom of the final row may exist. If this is true,
    /// then this extra padding is automatically balanced between all four
    /// edges to minimize imbalance on one side. If this is false, the top
    /// left grid cell will always hug the edge with zero padding other than
    /// what may be specified with the other "window-padding" options.
    ///
    /// If other "window-padding" fields are set and this is true, this will
    /// still apply. The other padding is applied first and may affect how
    /// many grid cells actually exist, and this is applied last in order
    /// to balance the padding given a certain viewport size and grid cell size.
    @"window-padding-balance": bool = true,

    /// If true, new windows and tabs will inherit the font size of the previously
    /// focused window. If no window was previously focused, the default
    /// font size will be used. If this is false, the default font size
    /// specified in the configuration "font-size" will be used.
    @"window-inherit-font-size": bool = true,

    /// Whether to allow programs running in the terminal to read/write to
    /// the system clipboard (OSC 52, for googling). The default is to
    /// disallow clipboard reading but allow writing.
    @"clipboard-read": bool = false,
    @"clipboard-write": bool = true,

    /// Additional configuration files to read.
    @"config-file": RepeatableString = .{},

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn default(alloc_gpa: Allocator) Allocator.Error!Config {
        // Build up our basic config
        var result: Config = .{
            ._arena = ArenaAllocator.init(alloc_gpa),
        };
        errdefer result.deinit();
        const alloc = result._arena.?.allocator();

        // Add our default keybindings
        try result.keybind.set.put(
            alloc,
            .{ .key = .c, .mods = .{ .super = true } },
            .{ .copy_to_clipboard = {} },
        );

        try result.keybind.set.put(
            alloc,
            .{ .key = .v, .mods = .{ .super = true } },
            .{ .paste_from_clipboard = {} },
        );

        try result.keybind.set.put(alloc, .{ .key = .up }, .{ .csi = "A" });
        try result.keybind.set.put(alloc, .{ .key = .down }, .{ .csi = "B" });
        try result.keybind.set.put(alloc, .{ .key = .right }, .{ .csi = "C" });
        try result.keybind.set.put(alloc, .{ .key = .left }, .{ .csi = "D" });
        try result.keybind.set.put(alloc, .{ .key = .home }, .{ .csi = "H" });
        try result.keybind.set.put(alloc, .{ .key = .end }, .{ .csi = "F" });
        try result.keybind.set.put(alloc, .{ .key = .page_up }, .{ .csi = "5~" });
        try result.keybind.set.put(alloc, .{ .key = .page_down }, .{ .csi = "6~" });

        // From xterm:
        // Note that F1 through F4 are prefixed with SS3 , while the other keys are
        // prefixed with CSI .  Older versions of xterm implement different escape
        // sequences for F1 through F4, with a CSI  prefix.  These can be activated
        // by setting the oldXtermFKeys resource.  However, since they do not
        // correspond to any hardware terminal, they have been deprecated.  (The
        // DEC VT220 reserves F1 through F5 for local functions such as Setup).
        try result.keybind.set.put(alloc, .{ .key = .f1 }, .{ .csi = "11~" });
        try result.keybind.set.put(alloc, .{ .key = .f2 }, .{ .csi = "12~" });
        try result.keybind.set.put(alloc, .{ .key = .f3 }, .{ .csi = "13~" });
        try result.keybind.set.put(alloc, .{ .key = .f4 }, .{ .csi = "14~" });
        try result.keybind.set.put(alloc, .{ .key = .f5 }, .{ .csi = "15~" });
        try result.keybind.set.put(alloc, .{ .key = .f6 }, .{ .csi = "17~" });
        try result.keybind.set.put(alloc, .{ .key = .f7 }, .{ .csi = "18~" });
        try result.keybind.set.put(alloc, .{ .key = .f8 }, .{ .csi = "19~" });
        try result.keybind.set.put(alloc, .{ .key = .f9 }, .{ .csi = "20~" });
        try result.keybind.set.put(alloc, .{ .key = .f10 }, .{ .csi = "21~" });
        try result.keybind.set.put(alloc, .{ .key = .f11 }, .{ .csi = "23~" });
        try result.keybind.set.put(alloc, .{ .key = .f12 }, .{ .csi = "24~" });

        // Fonts
        try result.keybind.set.put(
            alloc,
            .{ .key = .equal, .mods = .{ .super = true } },
            .{ .increase_font_size = 1 },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .minus, .mods = .{ .super = true } },
            .{ .decrease_font_size = 1 },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .zero, .mods = .{ .super = true } },
            .{ .reset_font_size = {} },
        );

        // Dev Mode
        try result.keybind.set.put(
            alloc,
            .{ .key = .down, .mods = .{ .shift = true, .super = true } },
            .{ .toggle_dev_mode = {} },
        );

        // Windowing
        try result.keybind.set.put(
            alloc,
            .{ .key = .n, .mods = .{ .super = true } },
            .{ .new_window = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .w, .mods = .{ .super = true } },
            .{ .close_window = {} },
        );
        if (comptime builtin.target.isDarwin()) {
            try result.keybind.set.put(
                alloc,
                .{ .key = .t, .mods = .{ .super = true } },
                .{ .new_tab = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .q, .mods = .{ .super = true } },
                .{ .quit = {} },
            );
        }

        return result;
    }

    pub fn finalize(self: *Config) !void {
        // If we have a font-family set and don't set the others, default
        // the others to the font family. This way, if someone does
        // --font-family=foo, then we try to get the stylized versions of
        // "foo" as well.
        if (self.@"font-family") |family| {
            const fields = &[_][]const u8{
                "font-family-bold",
                "font-family-italic",
                "font-family-bold-italic",
            };
            inline for (fields) |field| {
                if (@field(self, field) == null) {
                    @field(self, field) = family;
                }
            }
        }

        // The default for the working directory depends on the system.
        const wd = self.@"working-directory" orelse switch (builtin.os.tag) {
            .macos => if (c.getppid() == 1) "home" else "inherit",
            else => "inherit",
        };

        // If we are missing either a command or home directory, we need
        // to look up defaults which is kind of expensive.
        const wd_home = std.mem.eql(u8, "home", wd);
        if (self.command == null or wd_home) command: {
            const alloc = self._arena.?.allocator();

            // First look up the command using the SHELL env var.
            if (std.process.getEnvVarOwned(alloc, "SHELL")) |value| {
                log.debug("default shell source=env value={s}", .{value});
                self.command = value;

                // If we don't need the working directory, then we can exit now.
                if (!wd_home) break :command;
            } else |_| {}

            // We need the passwd entry for the remainder
            const pw = try passwd.get(alloc);
            if (self.command == null) {
                if (pw.shell) |sh| {
                    log.debug("default shell src=passwd value={s}", .{sh});
                    self.command = sh;
                }
            }

            if (wd_home) {
                if (pw.home) |home| {
                    log.debug("default working directory src=passwd value={s}", .{home});
                    self.@"working-directory" = home;
                }
            }
        }

        // If we have the special value "inherit" then set it to null which
        // does the same. In the future we should change to a tagged union.
        if (std.mem.eql(u8, wd, "inherit")) self.@"working-directory" = null;
    }
};

/// Color represents a color using RGB.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const Error = error{
        InvalidFormat,
    };

    /// Convert this to the terminal RGB struct
    pub fn toTerminalRGB(self: Color) terminal.color.RGB {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    pub fn parseCLI(input: ?[]const u8) !Color {
        return fromHex(input orelse return error.ValueRequired);
    }

    /// fromHex parses a color from a hex value such as #RRGGBB. The "#"
    /// is optional.
    pub fn fromHex(input: []const u8) !Color {
        // Trim the beginning '#' if it exists
        const trimmed = if (input.len != 0 and input[0] == '#') input[1..] else input;

        // We expect exactly 6 for RRGGBB
        if (trimmed.len != 6) return Error.InvalidFormat;

        // Parse the colors two at a time.
        var result: Color = undefined;
        comptime var i: usize = 0;
        inline while (i < 6) : (i += 2) {
            const v: u8 =
                ((try std.fmt.charToDigit(trimmed[i], 16)) * 16) +
                try std.fmt.charToDigit(trimmed[i + 1], 16);

            @field(result, switch (i) {
                0 => "r",
                2 => "g",
                4 => "b",
                else => unreachable,
            }) = v;
        }

        return result;
    }

    test "fromHex" {
        const testing = std.testing;

        try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.fromHex("#000000"));
        try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("#0A0B0C"));
        try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("0A0B0C"));
        try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.fromHex("FFFFFF"));
    }
};

/// Palette is the 256 color palette for 256-color mode. This is still
/// used by many terminal applications.
pub const Palette = struct {
    const Self = @This();

    /// The actual value that is updated as we parse.
    value: terminal.color.Palette = terminal.color.default,

    pub const Error = error{
        InvalidFormat,
    };

    pub fn parseCLI(
        self: *Self,
        input: ?[]const u8,
    ) !void {
        const value = input orelse return error.ValueRequired;
        const eqlIdx = std.mem.indexOf(u8, value, "=") orelse
            return Error.InvalidFormat;

        const key = try std.fmt.parseInt(u8, value[0..eqlIdx], 10);
        const rgb = try Color.parseCLI(value[eqlIdx + 1 ..]);
        self.value[key] = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }

    test "parseCLI" {
        const testing = std.testing;

        var p: Self = .{};
        try p.parseCLI("0=#AABBCC");
        try testing.expect(p.value[0].r == 0xAA);
        try testing.expect(p.value[0].g == 0xBB);
        try testing.expect(p.value[0].b == 0xCC);
    }

    test "parseCLI overflow" {
        const testing = std.testing;

        var p: Self = .{};
        try testing.expectError(error.Overflow, p.parseCLI("256=#AABBCC"));
    }
};

/// RepeatableString is a string value that can be repeated to accumulate
/// a list of strings. This isn't called "StringList" because I find that
/// sometimes leads to confusion that it _accepts_ a list such as
/// comma-separated values.
pub const RepeatableString = struct {
    const Self = @This();

    // Allocator for the list is the arena for the parent config.
    list: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse return error.ValueRequired;
        try self.list.append(alloc, value);
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        try list.parseCLI(alloc, "B");

        try testing.expectEqual(@as(usize, 2), list.list.items.len);
    }
};

/// Stores a set of keybinds.
pub const Keybinds = struct {
    set: inputpkg.Binding.Set = .{},

    pub fn parseCLI(self: *Keybinds, alloc: Allocator, input: ?[]const u8) !void {
        var copy: ?[]u8 = null;
        var value = value: {
            const value = input orelse return error.ValueRequired;

            // If we don't have a colon, use the value as-is, no copy
            if (std.mem.indexOf(u8, value, ":") == null)
                break :value value;

            // If we have a colon, we copy the whole value for now. We could
            // do this more efficiently later if we wanted to.
            const buf = try alloc.alloc(u8, value.len);
            copy = buf;

            std.mem.copy(u8, buf, value);
            break :value buf;
        };
        errdefer if (copy) |v| alloc.free(v);

        const binding = try inputpkg.Binding.parse(value);
        switch (binding.action) {
            .unbind => self.set.remove(binding.trigger),
            else => try self.set.put(alloc, binding.trigger, binding.action),
        }
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var set: Keybinds = .{};
        try set.parseCLI(alloc, "shift+a=copy_to_clipboard");
        try set.parseCLI(alloc, "shift+a=csi:hello");
    }
};

test {
    std.testing.refAllDecls(@This());
}
