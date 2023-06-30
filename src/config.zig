const config = @This();
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const inputpkg = @import("input.zig");
const passwd = @import("passwd.zig");
const terminal = @import("terminal/main.zig");
const internal_os = @import("os/main.zig");
const xdg = @import("xdg.zig");
const cli_args = @import("cli_args.zig");

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
    @"window-padding-x": u32 = 2,
    @"window-padding-y": u32 = 2,

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
    @"window-padding-balance": bool = false,

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

    /// Trims trailing whitespace on data that is copied to the clipboard.
    /// This does not affect data sent to the clipboard via "clipboard-write".
    @"clipboard-trim-trailing-spaces": bool = true,

    /// The time in milliseconds between clicks to consider a click a repeat
    /// (double, triple, etc.) or an entirely new single click. A value of
    /// zero will use a platform-specific default. The default on macOS
    /// is determined by the OS settings. On every other platform it is 500ms.
    @"click-repeat-interval": u32 = 0,

    /// Additional configuration files to read.
    @"config-file": RepeatableString = .{},

    // Confirms that a surface should be closed before closing it. This defaults
    // to true. If set to false, surfaces will close without any confirmation.
    @"confirm-close-surface": bool = true,

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Key is an enum of all the available configuration keys. This is used
    /// when paired with diff to determine what fields have changed in a config,
    /// amongst other things.
    pub const Key = key: {
        const field_infos = std.meta.fields(Config);
        var enumFields: [field_infos.len]std.builtin.Type.EnumField = undefined;
        var i: usize = 0;
        inline for (field_infos) |field| {
            // Ignore fields starting with "_" since they're internal and
            // not copied ever.
            if (field.name[0] == '_') continue;

            enumFields[i] = .{
                .name = field.name,
                .value = i,
            };
            i += 1;
        }

        var decls = [_]std.builtin.Type.Declaration{};
        break :key @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, field_infos.len - 1),
                .fields = enumFields[0..i],
                .decls = &decls,
                .is_exhaustive = true,
            },
        });
    };

    pub fn deinit(self: *Config) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Load the configuration according to the default rules:
    ///
    ///   1. Defaults
    ///   2. XDG Config File
    ///   3. CLI flags
    ///   4. Recursively defined configuration files
    ///
    pub fn load(alloc_gpa: Allocator) !Config {
        var result = try default(alloc_gpa);
        errdefer result.deinit();

        // If we have a configuration file in our home directory, parse that first.
        try result.loadDefaultFiles(alloc_gpa);

        // Parse the config from the CLI args
        try result.loadCliArgs(alloc_gpa);

        // Parse the config files that were added from our file and CLI args.
        try result.loadRecursiveFiles(alloc_gpa);
        try result.finalize();

        return result;
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
            .{ .key = .space, .mods = .{ .super = true, .alt = true, .ctrl = true } },
            .{ .reload_config = {} },
        );

        {
            // On macOS we default to super but Linux ctrl+shift since
            // ctrl+c is to kill the process.
            const mods: inputpkg.Mods = if (builtin.target.isDarwin())
                .{ .super = true }
            else
                .{ .ctrl = true, .shift = true };

            try result.keybind.set.put(
                alloc,
                .{ .key = .c, .mods = mods },
                .{ .copy_to_clipboard = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .v, .mods = mods },
                .{ .paste_from_clipboard = {} },
            );
        }

        // Some control keys
        try result.keybind.set.put(alloc, .{ .key = .up }, .{ .cursor_key = .{
            .normal = "\x1b[A",
            .application = "\x1bOA",
        } });
        try result.keybind.set.put(alloc, .{ .key = .down }, .{ .cursor_key = .{
            .normal = "\x1b[B",
            .application = "\x1bOB",
        } });
        try result.keybind.set.put(alloc, .{ .key = .right }, .{ .cursor_key = .{
            .normal = "\x1b[C",
            .application = "\x1bOC",
        } });
        try result.keybind.set.put(alloc, .{ .key = .left }, .{ .cursor_key = .{
            .normal = "\x1b[D",
            .application = "\x1bOD",
        } });
        try result.keybind.set.put(alloc, .{ .key = .home }, .{ .cursor_key = .{
            .normal = "\x1b[H",
            .application = "\x1bOH",
        } });
        try result.keybind.set.put(alloc, .{ .key = .end }, .{ .cursor_key = .{
            .normal = "\x1b[F",
            .application = "\x1bOF",
        } });

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
            .{ .key = .equal, .mods = ctrlOrSuper(.{}) },
            .{ .increase_font_size = 1 },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .minus, .mods = ctrlOrSuper(.{}) },
            .{ .decrease_font_size = 1 },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .zero, .mods = ctrlOrSuper(.{}) },
            .{ .reset_font_size = {} },
        );

        // Dev Mode
        try result.keybind.set.put(
            alloc,
            .{ .key = .down, .mods = .{ .shift = true, .super = true } },
            .{ .toggle_dev_mode = {} },
        );

        // Windowing
        if (comptime !builtin.target.isDarwin()) {
            try result.keybind.set.put(
                alloc,
                .{ .key = .n, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_window = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .w, .mods = .{ .ctrl = true, .shift = true } },
                .{ .close_surface = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .q, .mods = .{ .ctrl = true, .shift = true } },
                .{ .quit = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .f4, .mods = .{ .alt = true } },
                .{ .close_window = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .t, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_tab = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .left, .mods = .{ .ctrl = true, .shift = true } },
                .{ .previous_tab = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .right, .mods = .{ .ctrl = true, .shift = true } },
                .{ .next_tab = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .o, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_split = .right },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .e, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_split = .down },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .left_bracket, .mods = .{ .ctrl = true } },
                .{ .goto_split = .previous },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .right_bracket, .mods = .{ .ctrl = true } },
                .{ .goto_split = .next },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .up, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .top },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .down, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .bottom },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .left, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .left },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .right, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .right },
            );
        }
        {
            // Cmd+N for goto tab N
            const start = @intFromEnum(inputpkg.Key.one);
            const end = @intFromEnum(inputpkg.Key.nine);
            var i: usize = start;
            while (i <= end) : (i += 1) {
                // On macOS we default to super but everywhere else
                // is alt.
                const mods: inputpkg.Mods = if (builtin.target.isDarwin())
                    .{ .super = true }
                else
                    .{ .alt = true };

                try result.keybind.set.put(
                    alloc,
                    .{ .key = @enumFromInt(i), .mods = mods },
                    .{ .goto_tab = (i - start) + 1 },
                );
            }
        }

        // Mac-specific keyboard bindings.
        if (comptime builtin.target.isDarwin()) {
            try result.keybind.set.put(
                alloc,
                .{ .key = .q, .mods = .{ .super = true } },
                .{ .quit = {} },
            );

            try result.keybind.set.put(
                alloc,
                .{ .key = .k, .mods = .{ .super = true } },
                .{ .clear_screen = {} },
            );

            // Mac windowing
            try result.keybind.set.put(
                alloc,
                .{ .key = .n, .mods = .{ .super = true } },
                .{ .new_window = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .w, .mods = .{ .super = true } },
                .{ .close_surface = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .w, .mods = .{ .super = true, .shift = true } },
                .{ .close_window = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .t, .mods = .{ .super = true } },
                .{ .new_tab = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .left_bracket, .mods = .{ .super = true, .shift = true } },
                .{ .previous_tab = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .right_bracket, .mods = .{ .super = true, .shift = true } },
                .{ .next_tab = {} },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .d, .mods = .{ .super = true } },
                .{ .new_split = .right },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .d, .mods = .{ .super = true, .shift = true } },
                .{ .new_split = .down },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .left_bracket, .mods = .{ .super = true } },
                .{ .goto_split = .previous },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .right_bracket, .mods = .{ .super = true } },
                .{ .goto_split = .next },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .up, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .top },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .down, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .bottom },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .left, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .left },
            );
            try result.keybind.set.put(
                alloc,
                .{ .key = .right, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .right },
            );
        }

        return result;
    }

    /// This sets either "ctrl" or "super" to true (but not both)
    /// on mods depending on if the build target is Mac or not. On
    /// Mac, we default to super (i.e. super+c for copy) and on
    /// non-Mac we default to ctrl (i.e. ctrl+c for copy).
    fn ctrlOrSuper(mods: inputpkg.Mods) inputpkg.Mods {
        var copy = mods;
        if (comptime builtin.target.isDarwin()) {
            copy.super = true;
        } else {
            copy.ctrl = true;
        }

        return copy;
    }

    /// Load the configuration from the default file locations. Currently,
    /// this loads from $XDG_CONFIG_HOME/ghostty/config.
    pub fn loadDefaultFiles(self: *Config, alloc: Allocator) !void {
        const home_config_path = try xdg.config(alloc, .{ .subdir = "ghostty/config" });
        defer alloc.free(home_config_path);

        const cwd = std.fs.cwd();
        if (cwd.openFile(home_config_path, .{})) |file| {
            defer file.close();
            std.log.info("reading configuration file path={s}", .{home_config_path});

            var buf_reader = std.io.bufferedReader(file.reader());
            var iter = cli_args.lineIterator(buf_reader.reader());
            try cli_args.parse(Config, alloc, self, &iter);
        } else |err| switch (err) {
            error.FileNotFound => std.log.info(
                "homedir config not found, not loading path={s}",
                .{home_config_path},
            ),

            else => std.log.warn(
                "error reading homedir config file, not loading err={} path={s}",
                .{ err, home_config_path },
            ),
        }
    }

    /// Load and parse the CLI args.
    pub fn loadCliArgs(self: *Config, alloc_gpa: Allocator) !void {
        switch (builtin.os.tag) {
            .windows => {},

            // Fast-path if we are non-Windows and no args, do nothing.
            else => if (std.os.argv.len <= 1) return,
        }

        // Parse the config from the CLI args
        var iter = try std.process.argsWithAllocator(alloc_gpa);
        defer iter.deinit();
        try cli_args.parse(Config, alloc_gpa, self, &iter);
    }

    /// Load and parse the config files that were added in the "config-file" key.
    pub fn loadRecursiveFiles(self: *Config, alloc: Allocator) !void {
        // TODO(mitchellh): we should parse the files form the homedir first
        // TODO(mitchellh): support nesting (config-file in a config file)
        // TODO(mitchellh): detect cycles when nesting

        if (self.@"config-file".list.items.len == 0) return;

        const cwd = std.fs.cwd();
        const len = self.@"config-file".list.items.len;
        for (self.@"config-file".list.items) |path| {
            var file = try cwd.openFile(path, .{});
            defer file.close();

            var buf_reader = std.io.bufferedReader(file.reader());
            var iter = cli_args.lineIterator(buf_reader.reader());
            try cli_args.parse(Config, alloc, self, &iter);

            // We don't currently support adding more config files to load
            // from within a loaded config file. This can be supported
            // later.
            if (self.@"config-file".list.items.len > len)
                return error.ConfigFileInConfigFile;
        }
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
        // to look up defaults which is kind of expensive. We only do this
        // on desktop.
        const wd_home = std.mem.eql(u8, "home", wd);
        if (comptime !builtin.target.isWasm()) {
            if (self.command == null or wd_home) command: {
                const alloc = self._arena.?.allocator();

                // First look up the command using the SHELL env var if needed.
                // We don't do this in flatpak because SHELL in Flatpak is always
                // set to /bin/sh.
                if (self.command) |cmd|
                    log.info("shell src=config value={s}", .{cmd})
                else {
                    if (!internal_os.isFlatpak()) {
                        if (std.process.getEnvVarOwned(alloc, "SHELL")) |value| {
                            log.info("default shell source=env value={s}", .{value});
                            self.command = value;

                            // If we don't need the working directory, then we can exit now.
                            if (!wd_home) break :command;
                        } else |_| {}
                    }
                }

                // We need the passwd entry for the remainder
                const pw = try passwd.get(alloc);
                if (self.command == null) {
                    if (pw.shell) |sh| {
                        log.info("default shell src=passwd value={s}", .{sh});
                        self.command = sh;
                    }
                }

                if (wd_home) {
                    if (pw.home) |home| {
                        log.info("default working directory src=passwd value={s}", .{home});
                        self.@"working-directory" = home;
                    }
                }

                if (self.command == null) {
                    log.warn("no default shell found, will default to using sh", .{});
                }
            }
        }

        // If we have the special value "inherit" then set it to null which
        // does the same. In the future we should change to a tagged union.
        if (std.mem.eql(u8, wd, "inherit")) self.@"working-directory" = null;

        // Default our click interval
        if (self.@"click-repeat-interval" == 0) {
            self.@"click-repeat-interval" = internal_os.clickInterval() orelse 500;
        }
    }

    /// Create a shallow copy of this config. This will share all the memory
    /// allocated with the previous config but will have a new arena for
    /// any changes or new allocations. The config should have `deinit`
    /// called when it is complete.
    ///
    /// Beware: these shallow clones are not meant for a long lifetime,
    /// they are just meant to exist temporarily for the duration of some
    /// modifications. It is very important that the original config not
    /// be deallocated while shallow clones exist.
    pub fn shallowClone(self: *const Config, alloc_gpa: Allocator) Config {
        var result = self.*;
        result._arena = ArenaAllocator.init(alloc_gpa);
        return result;
    }

    /// Create a copy of this configuration. This is useful as a starting
    /// point for modifying a configuration since a config can NOT be
    /// modified once it is in use by an app or surface.
    pub fn clone(self: *const Config, alloc_gpa: Allocator) !Config {
        // Start with an empty config with a new arena we're going
        // to use for all our copies.
        var result: Config = .{
            ._arena = ArenaAllocator.init(alloc_gpa),
        };
        errdefer result.deinit();
        const alloc = result._arena.?.allocator();

        inline for (@typeInfo(Config).Struct.fields) |field| {
            if (!@hasField(Key, field.name)) continue;
            @field(result, field.name) = try cloneValue(
                alloc,
                field.type,
                @field(self, field.name),
            );
        }

        return result;
    }

    fn cloneValue(alloc: Allocator, comptime T: type, src: T) !T {
        // Do known named types first
        switch (T) {
            []const u8 => return try alloc.dupe(u8, src),
            [:0]const u8 => return try alloc.dupeZ(u8, src),

            else => {},
        }

        // Back into types of types
        switch (@typeInfo(T)) {
            inline .Bool,
            .Int,
            => return src,

            .Optional => |info| return try cloneValue(
                alloc,
                info.child,
                src orelse return null,
            ),

            .Struct => return try src.clone(alloc),

            else => {
                @compileLog(T);
                @compileError("unsupported field type");
            },
        }
    }

    /// Returns an iterator that goes through each changed field from
    /// old to new. The order of old or new do not matter.
    pub fn changeIterator(old: *const Config, new: *const Config) ChangeIterator {
        return .{
            .old = old,
            .new = new,
        };
    }

    /// Returns true if the given key has changed from old to new. This
    /// requires the key to be comptime known to make this more efficient.
    pub fn changed(self: *const Config, new: *const Config, comptime key: Key) bool {
        // Get the field at comptime
        const field = comptime field: {
            const fields = std.meta.fields(Config);
            for (fields) |field| {
                if (@field(Key, field.name) == key) {
                    break :field field;
                }
            }

            unreachable;
        };

        const old_value = @field(self, field.name);
        const new_value = @field(new, field.name);
        return !equal(field.type, old_value, new_value);
    }

    /// This yields a key for every changed field between old and new.
    pub const ChangeIterator = struct {
        old: *const Config,
        new: *const Config,
        i: usize = 0,

        pub fn next(self: *ChangeIterator) ?Key {
            const fields = comptime std.meta.fields(Key);
            while (self.i < fields.len) {
                switch (self.i) {
                    inline 0...(fields.len - 1) => |i| {
                        const field = fields[i];
                        const key = @field(Key, field.name);
                        self.i += 1;
                        if (self.old.changed(self.new, key)) return key;
                    },

                    else => unreachable,
                }
            }

            return null;
        }
    };

    test "clone default" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var source = try Config.default(alloc);
        defer source.deinit();
        var dest = try source.clone(alloc);
        defer dest.deinit();

        // Should have no changes
        var it = source.changeIterator(&dest);
        try testing.expectEqual(@as(?Key, null), it.next());

        // I want to do this but this doesn't work (the API doesn't work)
        // try testing.expectEqualDeep(dest, source);
    }

    test "changed" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var source = try Config.default(alloc);
        defer source.deinit();
        var dest = try source.clone(alloc);
        defer dest.deinit();
        dest.@"font-family" = "something else";

        try testing.expect(source.changed(&dest, .@"font-family"));
        try testing.expect(!source.changed(&dest, .@"font-size"));
    }
};

/// A config-specific helper to determine if two values of the same
/// type are equal. This isn't the same as std.mem.eql or std.testing.equals
/// because we expect structs to implement their own equality.
///
/// This also doesn't support ALL Zig types, because we only add to it
/// as we need types for the config.
fn equal(comptime T: type, old: T, new: T) bool {
    // Do known named types first
    switch (T) {
        inline []const u8,
        [:0]const u8,
        => return std.mem.eql(u8, old, new),

        else => {},
    }

    // Back into types of types
    switch (@typeInfo(T)) {
        .Void => return true,

        inline .Bool,
        .Int,
        .Enum,
        => return old == new,

        .Optional => |info| {
            if (old == null and new == null) return true;
            if (old == null or new == null) return false;
            return equal(info.child, old.?, new.?);
        },

        .Struct => |info| {
            if (@hasDecl(T, "equal")) return old.equal(new);

            // If a struct doesn't declare an "equal" function, we fall back
            // to a recursive field-by-field compare.
            inline for (info.fields) |field_info| {
                if (!equal(
                    field_info.type,
                    @field(old, field_info.name),
                    @field(new, field_info.name),
                )) return false;
            }
            return true;
        },

        .Union => |info| {
            const tag_type = info.tag_type.?;
            const old_tag = std.meta.activeTag(old);
            const new_tag = std.meta.activeTag(new);
            if (old_tag != new_tag) return false;

            inline for (info.fields) |field_info| {
                if (@field(tag_type, field_info.name) == old_tag) {
                    return equal(
                        field_info.type,
                        @field(old, field_info.name),
                        @field(new, field_info.name),
                    );
                }
            }

            unreachable;
        },

        else => {
            @compileLog(T);
            @compileError("unsupported field type");
        },
    }
}

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

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: Color, _: Allocator) !Color {
        return self;
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Color, other: Color) bool {
        return std.meta.eql(self, other);
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

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: Self, _: Allocator) !Self {
        return self;
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
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

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Self, alloc: Allocator) !Self {
        return .{
            .list = try self.list.clone(alloc),
        };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.list.items;
        const itemsB = other.list.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        } else return true;
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

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Keybinds, alloc: Allocator) !Keybinds {
        return .{
            .set = .{
                .bindings = try self.set.bindings.clone(alloc),
            },
        };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Keybinds, other: Keybinds) bool {
        const self_map = self.set.bindings;
        const other_map = other.set.bindings;
        if (self_map.count() != other_map.count()) return false;

        var it = self_map.iterator();
        while (it.next()) |self_entry| {
            const other_entry = other_map.getEntry(self_entry.key_ptr.*) orelse
                return false;
            if (!config.equal(
                inputpkg.Binding.Action,
                self_entry.value_ptr.*,
                other_entry.value_ptr.*,
            )) return false;
        }

        return true;
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

// Wasm API.
pub const Wasm = if (!builtin.target.isWasm()) struct {} else struct {
    const wasm = @import("os/wasm.zig");
    const alloc = wasm.alloc;

    /// Create a new configuration filled with the initial default values.
    export fn config_new() ?*Config {
        const result = alloc.create(Config) catch |err| {
            log.err("error allocating config err={}", .{err});
            return null;
        };

        result.* = Config.default(alloc) catch |err| {
            log.err("error creating config err={}", .{err});
            return null;
        };

        return result;
    }

    export fn config_free(ptr: ?*Config) void {
        if (ptr) |v| {
            v.deinit();
            alloc.destroy(v);
        }
    }

    /// Load the configuration from a string in the same format as
    /// the file-based syntax for the desktop version of the terminal.
    export fn config_load_string(
        self: *Config,
        str: [*]const u8,
        len: usize,
    ) void {
        config_load_string_(self, str[0..len]) catch |err| {
            log.err("error loading config err={}", .{err});
        };
    }

    fn config_load_string_(self: *Config, str: []const u8) !void {
        var fbs = std.io.fixedBufferStream(str);
        var iter = cli_args.lineIterator(fbs.reader());
        try cli_args.parse(Config, alloc, self, &iter);
    }

    export fn config_finalize(self: *Config) void {
        self.finalize() catch |err| {
            log.err("error finalizing config err={}", .{err});
        };
    }
};

// C API.
pub const CAPI = struct {
    const global = &@import("main.zig").state;

    /// Create a new configuration filled with the initial default values.
    export fn ghostty_config_new() ?*Config {
        const result = global.alloc.create(Config) catch |err| {
            log.err("error allocating config err={}", .{err});
            return null;
        };

        result.* = Config.default(global.alloc) catch |err| {
            log.err("error creating config err={}", .{err});
            return null;
        };

        return result;
    }

    export fn ghostty_config_free(ptr: ?*Config) void {
        if (ptr) |v| {
            v.deinit();
            global.alloc.destroy(v);
        }
    }

    /// Load the configuration from the CLI args.
    export fn ghostty_config_load_cli_args(self: *Config) void {
        self.loadCliArgs(global.alloc) catch |err| {
            log.err("error loading config err={}", .{err});
        };
    }

    /// Load the configuration from a string in the same format as
    /// the file-based syntax for the desktop version of the terminal.
    export fn ghostty_config_load_string(
        self: *Config,
        str: [*]const u8,
        len: usize,
    ) void {
        config_load_string_(self, str[0..len]) catch |err| {
            log.err("error loading config err={}", .{err});
        };
    }

    fn config_load_string_(self: *Config, str: []const u8) !void {
        var fbs = std.io.fixedBufferStream(str);
        var iter = cli_args.lineIterator(fbs.reader());
        try cli_args.parse(Config, global.alloc, self, &iter);
    }

    /// Load the configuration from the default file locations. This
    /// is usually done first. The default file locations are locations
    /// such as the home directory.
    export fn ghostty_config_load_default_files(self: *Config) void {
        self.loadDefaultFiles(global.alloc) catch |err| {
            log.err("error loading config err={}", .{err});
        };
    }

    /// Load the configuration from the user-specified configuration
    /// file locations in the previously loaded configuration. This will
    /// recursively continue to load up to a built-in limit.
    export fn ghostty_config_load_recursive_files(self: *Config) void {
        self.loadRecursiveFiles(global.alloc) catch |err| {
            log.err("error loading config err={}", .{err});
        };
    }

    export fn ghostty_config_finalize(self: *Config) void {
        self.finalize() catch |err| {
            log.err("error finalizing config err={}", .{err});
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
