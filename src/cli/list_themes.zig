const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Config = @import("../config/Config.zig");
const themepkg = @import("../config/theme.zig");
const tui = @import("tui.zig");
const internal_os = @import("../os/main.zig");
const global_state = &@import("../global.zig").state;

const vaxis = @import("vaxis");
const zf = @import("zf");

// When the number of filtered themes is less than or equal to this threshold,
// the window position will be reset to 0 to show all results from the top.
// This ensures better visibility for small result sets while maintaining
// scroll position for larger lists.
const SMALL_LIST_THRESHOLD = 10;

pub const Options = struct {
    /// If true, print the full path to the theme.
    path: bool = false,

    /// If true, force a plain list of themes.
    plain: bool = false,

    /// Specifies the color scheme of the themes to include in the list.
    color: enum { all, dark, light } = .all,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

const ThemeListElement = struct {
    location: themepkg.Location,
    path: []const u8,
    theme: []const u8,
    rank: ?f64 = null,

    fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
        // TODO: use Unicode-aware comparison
        return std.ascii.orderIgnoreCase(lhs.theme, rhs.theme) == .lt;
    }

    pub fn toUri(self: *const ThemeListElement, alloc: std.mem.Allocator) ![]const u8 {
        const uri = std.Uri{
            .scheme = "file",
            .host = .{ .raw = "" },
            .path = .{ .raw = self.path },
        };
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();
        try uri.writeToStream(.{ .scheme = true, .authority = true, .path = true }, buf.writer());
        return buf.toOwnedSlice();
    }
};

/// The `list-themes` command is used to preview or list all the available
/// themes for Ghostty.
///
/// If this command is run from a TTY, a TUI preview of the themes will be
/// shown. While in the preview, `F1` will bring up a help screen and `ESC` will
/// exit the preview. Other keys that can be used to navigate the preview are
/// listed in the help screen.
///
/// If this command is not run from a TTY, or the output is piped to another
/// command, a plain list of theme names will be printed to the screen. A plain
/// list can be forced using the `--plain` CLI flag.
///
/// Two different directories will be searched for themes.
///
/// The first directory is the `themes` subdirectory of your Ghostty
/// configuration directory. This is `$XDG_CONFIG_HOME/ghostty/themes` or
/// `~/.config/ghostty/themes`.
///
/// The second directory is the `themes` subdirectory of the Ghostty resources
/// directory. Ghostty ships with a multitude of themes that will be installed
/// into this directory. On macOS, this directory is the
/// `Ghostty.app/Contents/Resources/ghostty/themes`. On Linux, this directory
/// is the `share/ghostty/themes` (wherever you installed the Ghostty "share"
/// directory). If you're running Ghostty from the source, this is the
/// `zig-out/share/ghostty/themes` directory.
///
/// You can also set the `GHOSTTY_RESOURCES_DIR` environment variable to point
/// to the resources directory.
///
/// Flags:
///
///   * `--path`: Show the full path to the theme.
///
///   * `--plain`: Force a plain listing of themes.
///
///   * `--color`: Specify the color scheme of the themes included in the list.
///                This can be `dark`, `light`, or `all`. The default is `all`.
pub fn run(gpa_alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(gpa_alloc);
        defer iter.deinit();
        try args.parse(Options, gpa_alloc, &opts, &iter);
    }

    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    const alloc = arena.allocator();

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    const resources_dir = global_state.resources_dir.app();
    if (resources_dir == null)
        try stderr.print("Could not find the Ghostty resources directory. Please ensure " ++
            "that Ghostty is installed correctly.\n", .{});

    var count: usize = 0;

    var themes = std.ArrayList(ThemeListElement).init(alloc);

    var it = themepkg.LocationIterator{ .arena_alloc = arena.allocator() };

    while (try it.next()) |loc| {
        var dir = std.fs.cwd().openDir(loc.dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                std.debug.print("error trying to open {s}: {}\n", .{ loc.dir, err });
                continue;
            },
        };
        defer dir.close();

        var walker = dir.iterate();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {
                    if (std.mem.eql(u8, entry.name, ".DS_Store"))
                        continue;
                    count += 1;

                    const path = try std.fs.path.join(alloc, &.{ loc.dir, entry.name });
                    // if there is no need to filter just append the theme to the list
                    if (opts.color == .all) {
                        try themes.append(.{
                            .path = path,
                            .location = loc.location,
                            .theme = try alloc.dupe(u8, entry.name),
                        });
                        continue;
                    }

                    // otherwise check if the theme should be included based on the provided options
                    var config = try Config.default(alloc);
                    defer config.deinit();
                    try config.loadFile(config._arena.?.allocator(), path);

                    if (shouldIncludeTheme(opts, config)) {
                        try themes.append(.{
                            .path = path,
                            .location = loc.location,
                            .theme = try alloc.dupe(u8, entry.name),
                        });
                    }
                },
                else => {},
            }
        }
    }

    if (count == 0) {
        try stderr.print("No themes found, check to make sure that the themes were installed correctly.", .{});
        return 1;
    }

    std.mem.sortUnstable(ThemeListElement, themes.items, {}, ThemeListElement.lessThan);

    if (tui.can_pretty_print and !opts.plain and std.posix.isatty(std.io.getStdOut().handle)) {
        try preview(gpa_alloc, themes.items);
        return 0;
    }

    for (themes.items) |theme| {
        if (opts.path)
            try stdout.print("{s} ({s}) {s}\n", .{ theme.theme, @tagName(theme.location), theme.path })
        else
            try stdout.print("{s} ({s})\n", .{ theme.theme, @tagName(theme.location) });
    }

    return 0;
}

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    color_scheme: vaxis.Color.Scheme,
    winsize: vaxis.Winsize,
};

const Preview = struct {
    allocator: std.mem.Allocator,
    should_quit: bool,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    mouse: ?vaxis.Mouse,
    themes: []ThemeListElement,
    filtered: std.ArrayList(usize),
    current: usize,
    window: usize,
    hex: bool,
    mode: enum {
        normal,
        help,
        search,
        save,
    },
    color_scheme: vaxis.Color.Scheme,
    text_input: vaxis.widgets.TextInput,

    pub fn init(allocator: std.mem.Allocator, themes: []ThemeListElement) !*Preview {
        const self = try allocator.create(Preview);

        self.* = .{
            .allocator = allocator,
            .should_quit = false,
            .tty = try vaxis.Tty.init(),
            .vx = try vaxis.init(allocator, .{}),
            .mouse = null,
            .themes = themes,
            .filtered = try std.ArrayList(usize).initCapacity(allocator, themes.len),
            .current = 0,
            .window = 0,
            .hex = false,
            .mode = .normal,
            .color_scheme = .light,
            .text_input = vaxis.widgets.TextInput.init(allocator, &self.vx.unicode),
        };

        for (0..themes.len) |i| {
            try self.filtered.append(i);
        }

        return self;
    }

    pub fn deinit(self: *Preview) void {
        const allocator = self.allocator;
        self.filtered.deinit();
        self.text_input.deinit();
        self.vx.deinit(allocator, self.tty.anyWriter());
        self.tty.deinit();
        allocator.destroy(self);
    }

    pub fn run(self: *Preview) !void {
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();

        try self.vx.enterAltScreen(self.tty.anyWriter());
        try self.vx.setTitle(self.tty.anyWriter(), "👻 Ghostty Theme Preview 👻");
        try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(self.tty.anyWriter(), true);
        if (self.vx.caps.color_scheme_updates)
            try self.vx.subscribeToColorSchemeUpdates(self.tty.anyWriter());

        while (!self.should_quit) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            loop.pollEvent();
            while (loop.tryEvent()) |event| {
                try self.update(event, alloc);
            }
            try self.draw(alloc);

            var buffered = self.tty.bufferedWriter();
            try self.vx.render(buffered.writer().any());
            try buffered.flush();
        }
    }

    fn updateFiltered(self: *Preview) !void {
        const relative = self.current -| self.window;
        var selected: []const u8 = undefined;
        if (self.filtered.items.len > 0) {
            selected = self.themes[self.filtered.items[self.current]].theme;
        }

        const hash_algorithm = std.hash.Wyhash;

        const old_digest = d: {
            var hash = hash_algorithm.init(0);
            for (self.filtered.items) |item|
                hash.update(std.mem.asBytes(&item));
            break :d hash.final();
        };

        self.filtered.clearRetainingCapacity();

        if (self.text_input.buf.realLength() > 0) {
            const first_half = self.text_input.buf.firstHalf();
            const second_half = self.text_input.buf.secondHalf();

            const buffer = try self.allocator.alloc(u8, first_half.len + second_half.len);
            defer self.allocator.free(buffer);

            @memcpy(buffer[0..first_half.len], first_half);
            @memcpy(buffer[first_half.len..], second_half);

            const string = try std.ascii.allocLowerString(self.allocator, buffer);
            defer self.allocator.free(string);

            var tokens = std.ArrayList([]const u8).init(self.allocator);
            defer tokens.deinit();

            var it = std.mem.tokenizeScalar(u8, string, ' ');
            while (it.next()) |token| try tokens.append(token);

            for (self.themes, 0..) |*theme, i| {
                theme.rank = zf.rank(theme.theme, tokens.items, .{
                    .to_lower = true,
                    .plain = true,
                });
                if (theme.rank != null) try self.filtered.append(i);
            }
        } else {
            for (self.themes, 0..) |*theme, i| {
                try self.filtered.append(i);
                theme.rank = null;
            }
        }

        const new_digest = d: {
            var hash = hash_algorithm.init(0);
            for (self.filtered.items) |item|
                hash.update(std.mem.asBytes(&item));
            break :d hash.final();
        };

        if (old_digest == new_digest) return;

        if (self.filtered.items.len == 0) {
            self.current = 0;
            self.window = 0;
            return;
        }

        self.current, self.window = current: {
            if (selected.len == 0) break :current .{ 0, 0 };

            for (self.filtered.items, 0..) |index, i| {
                if (std.mem.eql(u8, self.themes[index].theme, selected)) {
                    // Keep the relative position but ensure all search results are visible
                    const new_window = i -| relative;
                    // If the new window would hide some results at the top, adjust it
                    break :current .{ i, if (self.filtered.items.len <= SMALL_LIST_THRESHOLD) 0 else new_window };
                }
            }
            break :current .{ 0, 0 };
        };
    }

    fn up(self: *Preview, count: usize) void {
        if (self.filtered.items.len == 0) {
            self.current = 0;
            return;
        }
        self.current -|= count;
    }

    fn down(self: *Preview, count: usize) void {
        if (self.filtered.items.len == 0) {
            self.current = 0;
            return;
        }
        self.current += count;
        if (self.current >= self.filtered.items.len)
            self.current = self.filtered.items.len - 1;
    }

    pub fn update(self: *Preview, event: Event, alloc: std.mem.Allocator) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }))
                    self.should_quit = true;
                switch (self.mode) {
                    .normal => {
                        if (key.matchesAny(&.{ 'q', vaxis.Key.escape }, .{}))
                            self.should_quit = true;
                        if (key.matchesAny(&.{ '?', vaxis.Key.f1 }, .{}))
                            self.mode = .help;
                        if (key.matches('h', .{ .ctrl = true }))
                            self.mode = .help;
                        if (key.matches('/', .{}))
                            self.mode = .search;
                        if (key.matchesAny(&.{ vaxis.Key.enter, vaxis.Key.kp_enter }, .{}))
                            self.mode = .save;
                        if (key.matchesAny(&.{ 'x', '/' }, .{ .ctrl = true })) {
                            self.text_input.buf.clearRetainingCapacity();
                            try self.updateFiltered();
                        }
                        if (key.matchesAny(&.{ vaxis.Key.home, vaxis.Key.kp_home }, .{}))
                            self.current = 0;
                        if (key.matchesAny(&.{ vaxis.Key.end, vaxis.Key.kp_end }, .{}))
                            self.current = self.filtered.items.len - 1;
                        if (key.matchesAny(&.{ 'j', '+', vaxis.Key.down, vaxis.Key.kp_down, vaxis.Key.kp_add }, .{}))
                            self.down(1);
                        if (key.matchesAny(&.{ vaxis.Key.page_down, vaxis.Key.kp_down }, .{}))
                            self.down(20);
                        if (key.matchesAny(&.{ 'k', '-', vaxis.Key.up, vaxis.Key.kp_up, vaxis.Key.kp_subtract }, .{}))
                            self.up(1);
                        if (key.matchesAny(&.{ vaxis.Key.page_up, vaxis.Key.kp_page_up }, .{}))
                            self.up(20);
                        if (key.matchesAny(&.{ 'h', 'x' }, .{}))
                            self.hex = true;
                        if (key.matches('d', .{}))
                            self.hex = false;
                        if (key.matches('c', .{}))
                            try self.vx.copyToSystemClipboard(
                                self.tty.anyWriter(),
                                self.themes[self.filtered.items[self.current]].theme,
                                alloc,
                            )
                        else if (key.matches('c', .{ .shift = true }))
                            try self.vx.copyToSystemClipboard(
                                self.tty.anyWriter(),
                                self.themes[self.filtered.items[self.current]].path,
                                alloc,
                            );
                    },
                    .help => {
                        if (key.matches('q', .{}))
                            self.should_quit = true;
                        if (key.matchesAny(&.{ '?', vaxis.Key.escape, vaxis.Key.f1 }, .{}))
                            self.mode = .normal;
                        if (key.matches('h', .{ .ctrl = true }))
                            self.mode = .normal;
                    },
                    .search => search: {
                        if (key.matchesAny(&.{ vaxis.Key.escape, vaxis.Key.enter }, .{})) {
                            self.mode = .normal;
                            break :search;
                        }
                        if (key.matchesAny(&.{ 'x', '/' }, .{ .ctrl = true })) {
                            self.text_input.clearRetainingCapacity();
                            try self.updateFiltered();
                            break :search;
                        }
                        try self.text_input.update(.{ .key_press = key });
                        try self.updateFiltered();
                    },
                    .save => {
                        if (key.matches('q', .{}))
                            self.should_quit = true;
                        if (key.matchesAny(&.{ vaxis.Key.escape, vaxis.Key.enter, vaxis.Key.kp_enter }, .{}))
                            self.mode = .normal;
                    },
                }
            },
            .color_scheme => |color_scheme| self.color_scheme = color_scheme,
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
        }
    }

    pub fn ui_fg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0x00, 0x00, 0x00 } },
            .dark => .{ .rgb = [_]u8{ 0xff, 0xff, 0xff } },
        };
    }

    pub fn ui_bg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xff, 0xff, 0xff } },
            .dark => .{ .rgb = [_]u8{ 0x00, 0x00, 0x00 } },
        };
    }

    pub fn ui_standard(self: *Preview) vaxis.Style {
        return .{
            .fg = self.ui_fg(),
            .bg = self.ui_bg(),
        };
    }

    pub fn ui_hover_bg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xbb, 0xbb, 0xbb } },
            .dark => .{ .rgb = [_]u8{ 0x22, 0x22, 0x22 } },
        };
    }

    pub fn ui_highlighted(self: *Preview) vaxis.Style {
        return .{
            .fg = self.ui_fg(),
            .bg = self.ui_hover_bg(),
        };
    }

    pub fn ui_selected_fg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0x00, 0xaa, 0x00 } },
            .dark => .{ .rgb = [_]u8{ 0x00, 0xaa, 0x00 } },
        };
    }

    pub fn ui_selected_bg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xaa, 0xaa, 0xaa } },
            .dark => .{ .rgb = [_]u8{ 0x33, 0x33, 0x33 } },
        };
    }

    pub fn ui_selected(self: *Preview) vaxis.Style {
        return .{
            .fg = self.ui_selected_fg(),
            .bg = self.ui_selected_bg(),
        };
    }

    pub fn ui_err_fg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xff, 0x00, 0x00 } },
            .dark => .{ .rgb = [_]u8{ 0xff, 0x00, 0x00 } },
        };
    }

    pub fn ui_err(self: *Preview) vaxis.Style {
        return .{
            .fg = self.ui_err_fg(),
            .bg = self.ui_bg(),
        };
    }

    pub fn draw(self: *Preview, alloc: std.mem.Allocator) !void {
        const win = self.vx.window();
        win.clear();

        self.vx.setMouseShape(.default);

        const theme_list = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = 32,
            .height = win.height,
        });

        var highlight: ?usize = null;

        if (self.mouse) |mouse| {
            self.mouse = null;
            if (self.mode == .normal) {
                if (mouse.button == .wheel_up) {
                    self.up(1);
                }
                if (mouse.button == .wheel_down) {
                    self.down(1);
                }
                if (theme_list.hasMouse(mouse)) |_| {
                    if (mouse.button == .left and mouse.type == .release) {
                        const selection = self.window + mouse.row;
                        if (selection < self.filtered.items.len) {
                            self.current = selection;
                        }
                    }
                    highlight = mouse.row;
                }
            }
        }

        if (self.filtered.items.len == 0) {
            self.current = 0;
            self.window = 0;
        } else {
            const start = self.window;
            const end = self.window + theme_list.height - 1;
            if (self.current > end)
                self.window = self.current - theme_list.height + 1;
            if (self.current < start)
                self.window = self.current;
            if (self.window >= self.filtered.items.len)
                self.window = self.filtered.items.len - 1;
        }

        theme_list.fill(.{ .style = self.ui_standard() });

        for (0..theme_list.height) |row_capture| {
            const row: u16 = @intCast(row_capture);
            const index = self.window + row;
            if (index >= self.filtered.items.len) break;

            const theme = self.themes[self.filtered.items[index]];

            const style: enum { normal, highlighted, selected } = style: {
                if (index == self.current) break :style .selected;
                if (highlight) |h| if (h == row) break :style .highlighted;
                break :style .normal;
            };

            if (style == .selected) {
                _ = theme_list.printSegment(
                    .{
                        .text = "❯ ",
                        .style = self.ui_selected(),
                    },
                    .{
                        .row_offset = row,
                        .col_offset = 0,
                    },
                );
            }
            _ = theme_list.printSegment(
                .{
                    .text = theme.theme,
                    .style = switch (style) {
                        .normal => self.ui_standard(),
                        .highlighted => self.ui_highlighted(),
                        .selected => self.ui_selected(),
                    },
                    .link = .{
                        .uri = try theme.toUri(alloc),
                    },
                },
                .{
                    .row_offset = row,
                    .col_offset = 2,
                },
            );
            if (style == .selected) {
                if (theme.theme.len < theme_list.width - 4) {
                    for (2 + theme.theme.len..theme_list.width - 2) |i_capture| {
                        const i: u16 = @intCast(i_capture);
                        _ = theme_list.printSegment(
                            .{
                                .text = " ",
                                .style = self.ui_selected(),
                            },
                            .{
                                .row_offset = row,
                                .col_offset = i,
                            },
                        );
                    }
                }
                _ = theme_list.printSegment(
                    .{
                        .text = " ❮",
                        .style = self.ui_selected(),
                    },
                    .{
                        .row_offset = row,
                        .col_offset = theme_list.width - 2,
                    },
                );
            }
        }

        try self.drawPreview(alloc, win, theme_list.x_off + theme_list.width);

        switch (self.mode) {
            .normal => {
                win.hideCursor();
            },
            .help => {
                win.hideCursor();
                const width = 60;
                const height = 20;
                const child = win.child(
                    .{
                        .x_off = win.width / 2 -| width / 2,
                        .y_off = win.height / 2 -| height / 2,
                        .width = width,
                        .height = height,
                        .border = .{
                            .where = .all,
                            .style = self.ui_standard(),
                        },
                    },
                );

                child.fill(.{ .style = self.ui_standard() });

                const key_help = [_]struct { keys: []const u8, help: []const u8 }{
                    .{ .keys = "^C, q, ESC", .help = "Quit." },
                    .{ .keys = "F1, ?, ^H", .help = "Toggle help window." },
                    .{ .keys = "k, ↑", .help = "Move up 1 theme." },
                    .{ .keys = "ScrollUp", .help = "Move up 1 theme." },
                    .{ .keys = "PgUp", .help = "Move up 20 themes." },
                    .{ .keys = "j, ↓", .help = "Move down 1 theme." },
                    .{ .keys = "ScrollDown", .help = "Move down 1 theme." },
                    .{ .keys = "PgDown", .help = "Move down 20 themes." },
                    .{ .keys = "h, x", .help = "Show palette numbers in hexadecimal." },
                    .{ .keys = "d", .help = "Show palette numbers in decimal." },
                    .{ .keys = "c", .help = "Copy theme name to the clipboard." },
                    .{ .keys = "C", .help = "Copy theme path to the clipboard." },
                    .{ .keys = "Home", .help = "Go to the start of the list." },
                    .{ .keys = "End", .help = "Go to the end of the list." },
                    .{ .keys = "/", .help = "Start search." },
                    .{ .keys = "^X, ^/", .help = "Clear search." },
                    .{ .keys = "⏎", .help = "Save theme or close search window." },
                };

                for (key_help, 0..) |help, captured_i| {
                    const i: u16 = @intCast(captured_i);
                    _ = child.printSegment(
                        .{
                            .text = help.keys,
                            .style = self.ui_standard(),
                        },
                        .{
                            .row_offset = i + 1,
                            .col_offset = 2,
                        },
                    );
                    _ = child.printSegment(
                        .{
                            .text = "—",
                            .style = self.ui_standard(),
                        },
                        .{
                            .row_offset = i + 1,
                            .col_offset = 15,
                        },
                    );
                    _ = child.printSegment(
                        .{
                            .text = help.help,
                            .style = self.ui_standard(),
                        },
                        .{
                            .row_offset = i + 1,
                            .col_offset = 17,
                        },
                    );
                }
            },
            .search => {
                const child = win.child(.{
                    .x_off = 20,
                    .y_off = win.height - 5,
                    .width = win.width - 40,
                    .height = 3,
                    .border = .{
                        .where = .all,
                        .style = self.ui_standard(),
                    },
                });
                child.fill(.{ .style = self.ui_standard() });
                self.text_input.drawWithStyle(child, self.ui_standard());
            },
            .save => {
                const theme = self.themes[self.filtered.items[self.current]];

                const width = 90;
                const height = 12;
                const child = win.child(
                    .{
                        .x_off = win.width / 2 -| width / 2,
                        .y_off = win.height / 2 -| height / 2,
                        .width = width,
                        .height = height,
                        .border = .{
                            .where = .all,
                            .style = self.ui_standard(),
                        },
                    },
                );

                child.fill(.{ .style = self.ui_standard() });

                const save_instructions = [_][]const u8{
                    "To apply this theme, add the following line to your Ghostty configuration:",
                    "",
                    try std.fmt.allocPrint(alloc, "theme = {s}", .{theme.theme}),
                    "",
                    "Save the configuration file and then reload it to apply the new theme.",
                    "For more details on configuration and themes, visit the Ghostty documentation:",
                    "",
                    "https://ghostty.org/docs/config/reference",
                };

                for (save_instructions, 0..) |instruction, captured_i| {
                    const i: u16 = @intCast(captured_i);
                    _ = child.printSegment(
                        .{
                            .text = instruction,
                            .style = self.ui_standard(),
                        },
                        .{
                            .row_offset = i + 1,
                            .col_offset = 2,
                        },
                    );
                }
            },
        }
    }

    pub fn drawPreview(self: *Preview, alloc: std.mem.Allocator, win: vaxis.Window, x_off_unconverted: i17) !void {
        const x_off: u16 = @intCast(x_off_unconverted);
        const width: u16 = win.width - x_off;

        if (self.filtered.items.len > 0) {
            const theme = self.themes[self.filtered.items[self.current]];

            var config = try Config.default(alloc);
            defer config.deinit();

            config.loadFile(config._arena.?.allocator(), theme.path) catch |err| {
                const theme_path_len: u16 = @intCast(theme.path.len);

                const child = win.child(
                    .{
                        .x_off = x_off,
                        .y_off = 0,
                        .width = width,
                        .height = win.height,
                    },
                );
                child.fill(.{ .style = self.ui_standard() });
                const middle = child.height / 2;
                {
                    const text = try std.fmt.allocPrint(alloc, "Unable to open {s} from:", .{theme.theme});
                    const text_len: u16 = @intCast(text.len);
                    _ = child.printSegment(
                        .{
                            .text = text,
                            .style = self.ui_err(),
                        },
                        .{
                            .row_offset = middle -| 1,
                            .col_offset = child.width / 2 -| text_len / 2,
                        },
                    );
                }
                {
                    _ = child.printSegment(
                        .{
                            .text = theme.path,
                            .style = self.ui_err(),
                            .link = .{
                                .uri = try theme.toUri(alloc),
                            },
                        },
                        .{
                            .row_offset = middle,
                            .col_offset = child.width / 2 -| theme_path_len / 2,
                        },
                    );
                }
                {
                    const text = try std.fmt.allocPrint(alloc, "{}", .{err});
                    const text_len: u16 = @intCast(text.len);
                    _ = child.printSegment(
                        .{
                            .text = text,
                            .style = self.ui_err(),
                        },
                        .{
                            .row_offset = middle + 1,
                            .col_offset = child.width / 2 -| text_len / 2,
                        },
                    );
                }
                return;
            };

            var next_start: u16 = 0;

            const fg: vaxis.Color = .{
                .rgb = [_]u8{
                    config.foreground.r,
                    config.foreground.g,
                    config.foreground.b,
                },
            };
            const bg: vaxis.Color = .{
                .rgb = [_]u8{
                    config.background.r,
                    config.background.g,
                    config.background.b,
                },
            };
            const standard: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
            };
            const standard_bold: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .bold = true,
            };
            const standard_italic: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .italic = true,
            };
            const standard_bold_italic: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .bold = true,
                .italic = true,
            };
            const standard_underline: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .ul_style = .single,
            };
            const standard_double_underline: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .ul_style = .double,
            };
            const standard_dashed_underline: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .ul_style = .dashed,
            };
            const standard_curly_underline: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .ul_style = .curly,
            };
            const standard_dotted_underline: vaxis.Style = .{
                .fg = fg,
                .bg = bg,
                .ul_style = .dotted,
            };

            {
                const theme_len: u16 = @intCast(theme.theme.len);
                const theme_path_len: u16 = @intCast(theme.path.len);
                const child = win.child(
                    .{
                        .x_off = x_off,
                        .y_off = next_start,
                        .width = width,
                        .height = 4,
                    },
                );
                child.fill(.{ .style = standard });
                _ = child.printSegment(
                    .{
                        .text = theme.theme,
                        .style = standard_bold_italic,
                        .link = .{
                            .uri = try theme.toUri(alloc),
                        },
                    },
                    .{
                        .row_offset = 1,
                        .col_offset = child.width / 2 -| theme_len / 2,
                    },
                );
                _ = child.printSegment(
                    .{
                        .text = theme.path,
                        .style = standard,
                        .link = .{
                            .uri = try theme.toUri(alloc),
                        },
                    },
                    .{
                        .row_offset = 2,
                        .col_offset = child.width / 2 -| theme_path_len / 2,
                        .wrap = .none,
                    },
                );
                next_start += child.height;
            }

            if (config._diagnostics.items().len > 0) {
                const diagnostic_items_len: u16 = @intCast(config._diagnostics.items().len);
                const child = win.child(
                    .{
                        .x_off = x_off,
                        .y_off = next_start,
                        .width = width,
                        .height = if (config._diagnostics.items().len == 0) 0 else 2 + diagnostic_items_len,
                    },
                );
                {
                    const text = "Problems were encountered trying to load the theme:";
                    const text_len: u16 = @intCast(text.len);
                    _ = child.printSegment(
                        .{
                            .text = text,
                            .style = self.ui_err(),
                        },
                        .{
                            .row_offset = 0,
                            .col_offset = child.width / 2 -| (text_len / 2),
                        },
                    );
                }

                var buf = std.ArrayList(u8).init(alloc);
                defer buf.deinit();
                for (config._diagnostics.items(), 0..) |diag, captured_i| {
                    const i: u16 = @intCast(captured_i);
                    try diag.write(buf.writer());
                    _ = child.printSegment(
                        .{
                            .text = buf.items,
                            .style = self.ui_err(),
                        },
                        .{
                            .row_offset = 2 + i,
                            .col_offset = 2,
                        },
                    );
                    buf.clearRetainingCapacity();
                }
                next_start += child.height;
            }
            {
                const child = win.child(.{
                    .x_off = x_off,
                    .y_off = next_start,
                    .width = width,
                    .height = 6,
                });

                child.fill(.{ .style = standard });

                for (0..16) |captured_i| {
                    const i: u16 = @intCast(captured_i);
                    const r = i / 8;
                    const c = i % 8;
                    const text = if (self.hex)
                        try std.fmt.allocPrint(alloc, " {x:0>2}", .{i})
                    else
                        try std.fmt.allocPrint(alloc, "{d:3}", .{i});
                    _ = child.printSegment(
                        .{
                            .text = text,
                            .style = standard,
                        },
                        .{
                            .row_offset = 3 * r,
                            .col_offset = c * 8,
                        },
                    );
                    _ = child.printSegment(
                        .{
                            .text = "████",
                            .style = .{
                                .fg = color(config, i),
                                .bg = bg,
                            },
                        },
                        .{
                            .row_offset = 3 * r,
                            .col_offset = 4 + c * 8,
                        },
                    );
                    _ = child.printSegment(
                        .{
                            .text = "████",
                            .style = .{
                                .fg = color(config, i),
                                .bg = bg,
                            },
                        },
                        .{
                            .row_offset = 3 * r + 1,
                            .col_offset = 4 + c * 8,
                        },
                    );
                }
                next_start += child.height;
            }
            {
                const child = win.child(
                    .{
                        .x_off = x_off,
                        .y_off = next_start,
                        .width = width,
                        .height = 24,
                    },
                );
                const bold: vaxis.Style = .{
                    .fg = fg,
                    .bg = bg,
                    .bold = true,
                };
                const color1: vaxis.Style = .{
                    .fg = color(config, 1),
                    .bg = bg,
                };
                const color2: vaxis.Style = .{
                    .fg = color(config, 2),
                    .bg = bg,
                };
                const color3: vaxis.Style = .{
                    .fg = color(config, 3),
                    .bg = bg,
                };
                const color4: vaxis.Style = .{
                    .fg = color(config, 4),
                    .bg = bg,
                };
                const color5: vaxis.Style = .{
                    .fg = color(config, 5),
                    .bg = bg,
                };
                const color6: vaxis.Style = .{
                    .fg = color(config, 6),
                    .bg = bg,
                };
                const color6ul: vaxis.Style = .{
                    .fg = color(config, 6),
                    .bg = bg,
                    .ul_style = .single,
                };
                const color10: vaxis.Style = .{
                    .fg = color(config, 10),
                    .bg = bg,
                };
                const color12: vaxis.Style = .{
                    .fg = color(config, 12),
                    .bg = bg,
                };
                const color238: vaxis.Style = .{
                    .fg = color(config, 238),
                    .bg = bg,
                };
                child.fill(.{ .style = standard });
                _ = child.print(
                    &.{
                        .{ .text = "→", .style = color2 },
                        .{ .text = " ", .style = standard },
                        .{ .text = "bat", .style = color4 },
                        .{ .text = " ", .style = standard },
                        .{ .text = "ziggzagg.zig", .style = color6ul },
                    },
                    .{
                        .row_offset = 0,
                        .col_offset = 2,
                    },
                );
                {
                    _ = child.print(
                        &.{
                            .{
                                .text = "───────┬",
                                .style = color238,
                            },
                        },
                        .{
                            .row_offset = 1,
                            .col_offset = 2,
                        },
                    );
                    if (child.width > 10) {
                        for (10..child.width) |captured_col| {
                            const col: u16 = @intCast(captured_col);
                            _ = child.print(
                                &.{
                                    .{
                                        .text = "─",
                                        .style = color238,
                                    },
                                },
                                .{
                                    .row_offset = 1,
                                    .col_offset = col,
                                },
                            );
                        }
                    }
                }
                _ = child.print(
                    &.{
                        .{
                            .text = "       │ ",
                            .style = color238,
                        },

                        .{
                            .text = "File: ",
                            .style = standard,
                        },

                        .{
                            .text = "ziggzagg.zig",
                            .style = bold,
                        },
                    },
                    .{
                        .row_offset = 2,
                        .col_offset = 2,
                    },
                );
                {
                    _ = child.print(
                        &.{
                            .{
                                .text = "───────┼",
                                .style = color238,
                            },
                        },
                        .{
                            .row_offset = 3,
                            .col_offset = 2,
                        },
                    );
                    if (child.width > 10) {
                        for (10..child.width) |captured_col| {
                            const col: u16 = @intCast(captured_col);
                            _ = child.print(
                                &.{
                                    .{
                                        .text = "─",
                                        .style = color238,
                                    },
                                },
                                .{
                                    .row_offset = 3,
                                    .col_offset = col,
                                },
                            );
                        }
                    }
                }
                _ = child.print(
                    &.{
                        .{ .text = "   1   │ ", .style = color238 },
                        .{ .text = "const", .style = color5 },
                        .{ .text = " std ", .style = standard },
                        .{ .text = "= @import", .style = color5 },
                        .{ .text = "(", .style = standard },
                        .{ .text = "\"std\"", .style = color10 },
                        .{ .text = ");", .style = standard },
                    },
                    .{
                        .row_offset = 4,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "   2   │", .style = color238 },
                    },
                    .{
                        .row_offset = 5,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "   3   │ ", .style = color238 },
                        .{ .text = "pub ", .style = color5 },
                        .{ .text = "fn ", .style = color12 },
                        .{ .text = "main", .style = color2 },
                        .{ .text = "() ", .style = standard },
                        .{ .text = "!", .style = color5 },
                        .{ .text = "void", .style = color12 },
                        .{ .text = " {", .style = standard },
                    },
                    .{
                        .row_offset = 6,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "   4   │     ", .style = color238 },
                        .{ .text = "const ", .style = color5 },
                        .{ .text = "stdout ", .style = standard },
                        .{ .text = "=", .style = color5 },
                        .{ .text = " std.io.getStdOut().writer();", .style = standard },
                    },
                    .{
                        .row_offset = 7,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "   5   │     ", .style = color238 },
                        .{ .text = "var ", .style = color5 },
                        .{ .text = "i:", .style = standard },
                        .{ .text = " usize", .style = color12 },
                        .{ .text = " =", .style = color5 },
                        .{ .text = " 1", .style = color4 },
                        .{ .text = ";", .style = standard },
                    },
                    .{
                        .row_offset = 8,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "   6   │     ", .style = color238 },
                        .{ .text = "while ", .style = color5 },
                        .{ .text = "(i ", .style = standard },
                        .{ .text = "<= ", .style = color5 },
                        .{ .text = "16", .style = color4 },
                        .{ .text = ") : (i ", .style = standard },
                        .{ .text = "+= ", .style = color5 },
                        .{ .text = "1", .style = color4 },
                        .{ .text = ") {", .style = standard },
                    },
                    .{
                        .row_offset = 9,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "   7   │         ", .style = color238 },
                        .{ .text = "if ", .style = color5 },
                        .{ .text = "(i ", .style = standard },
                        .{ .text = "% ", .style = color5 },
                        .{ .text = "15 ", .style = color4 },
                        .{ .text = "== ", .style = color5 },
                        .{ .text = "0", .style = color4 },
                        .{ .text = ") {", .style = standard },
                    },
                    .{
                        .row_offset = 10,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "   8   │             ", .style = color238 },
                        .{ .text = "try ", .style = color5 },
                        .{ .text = "stdout.writeAll(", .style = standard },
                        .{ .text = "\"ZiggZagg", .style = color10 },
                        .{ .text = "\\n", .style = color12 },
                        .{ .text = "\"", .style = color10 },
                        .{ .text = ");", .style = standard },
                    },
                    .{
                        .row_offset = 11,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "   9   │         ", .style = color238 },
                        .{ .text = "} ", .style = standard },
                        .{ .text = "else if ", .style = color5 },
                        .{ .text = "(i ", .style = standard },
                        .{ .text = "% ", .style = color5 },
                        .{ .text = "3 ", .style = color4 },
                        .{ .text = "== ", .style = color5 },
                        .{ .text = "0", .style = color4 },
                        .{ .text = ") {", .style = standard },
                    },
                    .{
                        .row_offset = 12,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "  10   │             ", .style = color238 },
                        .{ .text = "try ", .style = color5 },
                        .{ .text = "stdout.writeAll(", .style = standard },
                        .{ .text = "\"Zigg", .style = color10 },
                        .{ .text = "\\n", .style = color12 },
                        .{ .text = "\"", .style = color10 },
                        .{ .text = ");", .style = standard },
                    },
                    .{
                        .row_offset = 13,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "  11   │         ", .style = color238 },
                        .{ .text = "} ", .style = standard },
                        .{ .text = "else if ", .style = color5 },
                        .{ .text = "(i ", .style = standard },
                        .{ .text = "% ", .style = color5 },
                        .{ .text = "5 ", .style = color4 },
                        .{ .text = "== ", .style = color5 },
                        .{ .text = "0", .style = color4 },
                        .{ .text = ") {", .style = standard },
                    },
                    .{
                        .row_offset = 14,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "  12   │             ", .style = color238 },
                        .{ .text = "try ", .style = color5 },
                        .{ .text = "stdout.writeAll(", .style = standard },
                        .{ .text = "\"Zagg", .style = color10 },
                        .{ .text = "\\n", .style = color12 },
                        .{ .text = "\"", .style = color10 },
                        .{ .text = ");", .style = standard },
                    },
                    .{
                        .row_offset = 15,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "  13   │         ", .style = color238 },
                        .{ .text = "} ", .style = standard },
                        .{ .text = "else ", .style = color5 },
                        .{ .text = "{", .style = standard },
                    },
                    .{
                        .row_offset = 16,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "  14   │             ", .style = color238 },
                        .{ .text = "try ", .style = color5 },
                        .{ .text = "stdout.print(", .style = standard },
                        .{ .text = "\"{d}", .style = color10 },
                        .{ .text = "\\n", .style = color12 },
                        .{ .text = "\"", .style = color10 },
                        .{ .text = ", .{i});", .style = standard },
                    },
                    .{
                        .row_offset = 17,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "  15   │         ", .style = color238 },
                        .{ .text = "}", .style = standard },
                    },
                    .{
                        .row_offset = 18,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "  16   │     ", .style = color238 },
                        .{ .text = "}", .style = standard },
                    },
                    .{
                        .row_offset = 19,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "  17   │ ", .style = color238 },
                        .{ .text = "}", .style = standard },
                    },
                    .{
                        .row_offset = 20,
                        .col_offset = 2,
                    },
                );
                {
                    _ = child.print(
                        &.{
                            .{
                                .text = "───────┴",
                                .style = color238,
                            },
                        },
                        .{
                            .row_offset = 21,
                            .col_offset = 2,
                        },
                    );
                    if (child.width > 10) {
                        for (10..child.width) |captured_col| {
                            const col: u16 = @intCast(captured_col);
                            _ = child.print(
                                &.{
                                    .{
                                        .text = "─",
                                        .style = color238,
                                    },
                                },
                                .{
                                    .row_offset = 21,
                                    .col_offset = col,
                                },
                            );
                        }
                    }
                }
                _ = child.print(
                    &.{
                        .{ .text = "ghostty ", .style = color6 },
                        .{ .text = "on ", .style = standard },
                        .{ .text = " main ", .style = color4 },
                        .{ .text = "[+] ", .style = color1 },
                        .{ .text = "via ", .style = standard },
                        .{ .text = " v0.13.0 ", .style = color3 },
                        .{ .text = "via ", .style = standard },
                        .{ .text = "  impure (ghostty-env)", .style = color4 },
                    },
                    .{
                        .row_offset = 22,
                        .col_offset = 2,
                    },
                );
                _ = child.print(
                    &.{
                        .{ .text = "✦ ", .style = color4 },
                        .{ .text = "at ", .style = standard },
                        .{ .text = "10:36:15 ", .style = color3 },
                        .{ .text = "→", .style = color2 },
                    },
                    .{
                        .row_offset = 23,
                        .col_offset = 2,
                    },
                );
                next_start += child.height;
            }
            if (next_start < win.height) {
                const child = win.child(
                    .{
                        .x_off = x_off,
                        .y_off = next_start,
                        .width = width,
                        .height = win.height - next_start,
                    },
                );
                child.fill(.{ .style = standard });
                var it = std.mem.splitAny(u8, lorem_ipsum, " \n");
                var row: u16 = 1;
                var col: u16 = 2;
                while (row < child.height) {
                    const word = it.next() orelse line: {
                        it.reset();
                        break :line it.next() orelse unreachable;
                    };
                    const word_len: u16 = @intCast(word.len);
                    if (col + word.len > child.width) {
                        row += 1;
                        col = 2;
                    }
                    const style: vaxis.Style = style: {
                        if (std.mem.eql(u8, "ipsum", word)) break :style .{ .fg = color(config, 2), .bg = bg };
                        if (std.mem.eql(u8, "consectetur", word)) break :style standard_bold;
                        if (std.mem.eql(u8, "reprehenderit", word)) break :style standard_italic;
                        if (std.mem.eql(u8, "Praesent", word)) break :style standard_bold_italic;
                        if (std.mem.eql(u8, "auctor", word)) break :style standard_underline;
                        if (std.mem.eql(u8, "dui", word)) break :style standard_double_underline;
                        if (std.mem.eql(u8, "erat", word)) break :style standard_dashed_underline;
                        if (std.mem.eql(u8, "enim", word)) break :style standard_dotted_underline;
                        if (std.mem.eql(u8, "odio", word)) break :style standard_curly_underline;
                        break :style standard;
                    };
                    _ = child.printSegment(
                        .{
                            .text = word,
                            .style = style,
                        },
                        .{
                            .row_offset = row,
                            .col_offset = col,
                        },
                    );
                    col += word_len + 1;
                }
            }
        } else {
            const child = win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = win.width,
                .height = win.height,
            });
            child.fill(.{
                .style = self.ui_standard(),
            });

            _ = child.printSegment(.{
                .text = "No theme found!",
                .style = self.ui_standard(),
            }, .{
                .row_offset = win.height / 2 - 1,
                .col_offset = win.width / 2 - 7,
            });
        }
    }
};

fn color(config: Config, palette: usize) vaxis.Color {
    return .{
        .rgb = [_]u8{
            config.palette.value[palette].r,
            config.palette.value[palette].g,
            config.palette.value[palette].b,
        },
    };
}

const lorem_ipsum = @embedFile("lorem_ipsum.txt");

fn preview(allocator: std.mem.Allocator, themes: []ThemeListElement) !void {
    var app = try Preview.init(allocator, themes);
    defer app.deinit();
    try app.run();
}

fn shouldIncludeTheme(opts: Options, theme_config: Config) bool {
    const rf = @as(f32, @floatFromInt(theme_config.background.r)) / 255.0;
    const gf = @as(f32, @floatFromInt(theme_config.background.g)) / 255.0;
    const bf = @as(f32, @floatFromInt(theme_config.background.b)) / 255.0;
    const luminance = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
    const is_dark = luminance < 0.5;

    return (opts.color == .dark and is_dark) or (opts.color == .light and !is_dark);
}
