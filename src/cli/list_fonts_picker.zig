//! Interactive font picker used by `+list-fonts` when stdout is a TTY.
//!
//! The left pane is a searchable list of font families. The right pane shows,
//! if the terminal supports the Kitty graphics protocol, a sample rendered
//! with the highlighted family. The sample is rasterized by Ghostty's own
//! font code (the same faces and glyph renderer the terminal uses) and sent
//! to the terminal as an image, since a terminal can't draw some of its own
//! cells in a different font.
//!
//! The interface deliberately mirrors `+list-themes` (search box, help
//! dialog, selection style, mouse handling) and takes its colors from the
//! user's Ghostty configuration, including their theme.
const std = @import("std");
const vaxis = @import("vaxis");
const zf = @import("zf");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const global = @import("../global.zig");

const Config = configpkg.Config;

/// A font family and the names of the faces discovered for it.
pub const Family = struct {
    name: [:0]const u8,
    styles: []const []const u8,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    color_scheme: vaxis.Color.Scheme,
    winsize: vaxis.Winsize,
};

/// Text rendered in the preview, one entry per line.
const sample_lines = [_][]const u8{
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "abcdefghijklmnopqrstuvwxyz",
    "0123456789 {}[]()<>=+-*/&|",
    "fn main() -> !void { 0O 1lI }",
};

/// Pixel size of the rendered sample.
const sample_px = 28;
const sample_padding = 12;

/// Width of the family list pane in cells.
const list_width = 32;

const Rgb = [3]u8;

/// The colors the UI is drawn with. These mirror the roles `+list-themes`
/// uses (standard, highlighted, selected) but are derived from the user's
/// Ghostty configuration.
const Colors = struct {
    fg: Rgb,
    bg: Rgb,
    hover_bg: Rgb,
    selected_fg: Rgb,
    selected_bg: Rgb,
    dim: Rgb,

    /// Colors used when there is no usable configuration. These are the
    /// same values `+list-themes` uses.
    fn fallback(scheme: vaxis.Color.Scheme) Colors {
        return switch (scheme) {
            .light => .{
                .fg = .{ 0x00, 0x00, 0x00 },
                .bg = .{ 0xff, 0xff, 0xff },
                .hover_bg = .{ 0xbb, 0xbb, 0xbb },
                .selected_fg = .{ 0x00, 0xaa, 0x00 },
                .selected_bg = .{ 0xaa, 0xaa, 0xaa },
                .dim = .{ 0x80, 0x80, 0x80 },
            },
            .dark => .{
                .fg = .{ 0xff, 0xff, 0xff },
                .bg = .{ 0x00, 0x00, 0x00 },
                .hover_bg = .{ 0x22, 0x22, 0x22 },
                .selected_fg = .{ 0x00, 0xaa, 0x00 },
                .selected_bg = .{ 0x33, 0x33, 0x33 },
                .dim = .{ 0x80, 0x80, 0x80 },
            },
        };
    }

    fn fromConfig(config: *const Config) Colors {
        const fg: Rgb = .{ config.foreground.r, config.foreground.g, config.foreground.b };
        const bg: Rgb = .{ config.background.r, config.background.g, config.background.b };
        const green = config.palette.value[2];
        return .{
            .fg = fg,
            .bg = bg,
            .hover_bg = blend(bg, fg, 15),
            .selected_fg = .{ green.r, green.g, green.b },
            .selected_bg = blend(bg, fg, 30),
            .dim = blend(fg, bg, 50),
        };
    }

    /// Move `from` toward `to` by `percent` percent.
    fn blend(from: Rgb, to: Rgb, percent: u8) Rgb {
        var result: Rgb = undefined;
        for (&result, from, to) |*out, a, b| {
            const x: i32 = a;
            const y: i32 = b;
            out.* = @intCast(x + @divTrunc((y - x) * percent, 100));
        }
        return result;
    }
};

const KeyHelp = struct { keys: []const u8, help: []const u8 };

const key_help = [_]KeyHelp{
    .{ .keys = "^C, q, ESC", .help = "Quit." },
    .{ .keys = "F1, ?, ^H", .help = "Toggle help window." },
    .{ .keys = "k, ↑", .help = "Move up 1 font." },
    .{ .keys = "ScrollUp", .help = "Move up 1 font." },
    .{ .keys = "PgUp, ^U", .help = "Move up 20 fonts." },
    .{ .keys = "j, ↓", .help = "Move down 1 font." },
    .{ .keys = "ScrollDown", .help = "Move down 1 font." },
    .{ .keys = "PgDown, ^D", .help = "Move down 20 fonts." },
    .{ .keys = "Home, g", .help = "Go to the start of the list." },
    .{ .keys = "End, G", .help = "Go to the end of the list." },
    .{ .keys = "/", .help = "Start search." },
    .{ .keys = "^X, ^/", .help = "Clear search." },
    .{ .keys = "c", .help = "Copy font-family line to the clipboard." },
    .{ .keys = "⏎", .help = "Select font, print its config line and exit." },
};

/// Show the picker. Returns the chosen family name (borrowed from
/// `families`), or null if the user quit without choosing.
pub fn run(
    alloc: std.mem.Allocator,
    families: []const Family,
    lib: font.Library,
    disco: *font.Discover,
) !?[]const u8 {
    var buf: [4096]u8 = undefined;
    var picker = try Picker.init(alloc, families, lib, disco, &buf);
    defer picker.deinit();
    try picker.run();
    return picker.selected;
}

const Picker = struct {
    allocator: std.mem.Allocator,
    should_quit: bool = false,
    tty: vaxis.Tty,
    env_map: std.process.Environ.Map,
    vx: vaxis.Vaxis,

    families: []const Family,
    lib: font.Library,
    disco: *font.Discover,

    /// Indexes into `families` that match the current search.
    filtered: std.ArrayList(usize),
    current: usize = 0,
    window: usize = 0,
    mouse: ?vaxis.Mouse = null,
    mode: enum { normal, help, search } = .normal,
    text_input: vaxis.widgets.TextInput,
    color_scheme: vaxis.Color.Scheme = .light,

    /// The user's configuration, if it could be loaded. Colors and the
    /// currently configured font come from here.
    config: ?Config,
    cols: Colors,

    /// Index into `families` of the font currently set by `font-family`.
    current_font: ?usize = null,

    /// The family chosen with Enter.
    selected: ?[]const u8 = null,

    /// The sample image currently held by the terminal, and the family
    /// index it was rendered for.
    shown: ?struct { family: usize, image: vaxis.Image } = null,
    /// Set if rendering the sample for `shown_failed_for` failed.
    preview_failed_for: ?usize = null,

    pub fn init(
        allocator: std.mem.Allocator,
        families: []const Family,
        lib: font.Library,
        disco: *font.Discover,
        buf: []u8,
    ) !*Picker {
        const self = try allocator.create(Picker);
        errdefer allocator.destroy(self);

        // Load the user's configuration so the picker matches their theme.
        // Failing to load it isn't fatal, we just use fallback colors.
        const config: ?Config = Config.load(allocator) catch |err| config: {
            std.log.warn("unable to load config, using default colors err={}", .{err});
            break :config null;
        };

        self.* = .{
            .allocator = allocator,
            .config = config,
            .cols = if (config) |*c| .fromConfig(c) else .fallback(.light),
            .tty = try .init(global.io(), buf),
            .env_map = try global.environMap(),
            .vx = undefined,
            .families = families,
            .lib = lib,
            .disco = disco,
            .filtered = try .initCapacity(allocator, families.len),
            .text_input = .init(allocator),
        };
        errdefer if (self.config) |*c| c.deinit();
        self.vx = try vaxis.init(global.io(), allocator, &self.env_map, .{});
        try self.updateFiltered();
        self.selectConfiguredFont();
        return self;
    }

    /// Find the font set by `font-family` in the config, remember it so it
    /// can be marked in the list, and start with it selected.
    fn selectConfiguredFont(self: *Picker) void {
        const config = self.config orelse return;
        const list = config.@"font-family".list.items;
        if (list.len == 0) return;
        for (self.families, 0..) |family, i| {
            if (!std.ascii.eqlIgnoreCase(family.name, list[0])) continue;
            self.current_font = i;
            // The filter is empty at this point so indexes line up.
            self.current = i;
            return;
        }
    }

    pub fn deinit(self: *Picker) void {
        const allocator = self.allocator;
        self.filtered.deinit(allocator);
        self.text_input.deinit();
        if (self.config) |*c| c.deinit();
        self.vx.deinit(allocator, self.tty.writer());
        self.env_map.deinit();
        self.tty.deinit();
        allocator.destroy(self);
    }

    pub fn run(self: *Picker) !void {
        var loop: vaxis.Loop(Event) = .init(global.io(), &self.tty, &self.vx);
        try loop.start();
        defer loop.stop();

        const writer = self.tty.writer();
        try self.vx.enterAltScreen(writer);
        try self.vx.setTitle(writer, "👻 Ghostty Font Picker 👻");
        try self.vx.queryTerminal(writer, .fromSeconds(1));
        try self.vx.setMouseMode(writer, true);
        if (self.vx.caps.color_scheme_updates)
            try self.vx.subscribeToColorSchemeUpdates(writer);

        while (!self.should_quit) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            try loop.pollEvent();
            while (try loop.tryEvent()) |event| {
                try self.update(event, alloc);
            }
            try self.draw(alloc);

            try self.vx.render(writer);
            try writer.flush();
        }
    }

    fn updateFiltered(self: *Picker) !void {
        self.filtered.clearRetainingCapacity();
        self.current = 0;
        self.window = 0;

        const first = self.text_input.buf.firstHalf();
        const second = self.text_input.buf.secondHalf();
        if (first.len + second.len == 0) {
            for (0..self.families.len) |i| try self.filtered.append(self.allocator, i);
            return;
        }

        const query = try self.allocator.alloc(u8, first.len + second.len);
        defer self.allocator.free(query);
        @memcpy(query[0..first.len], first);
        @memcpy(query[first.len..], second);

        var tokens: std.ArrayList([]const u8) = .empty;
        defer tokens.deinit(self.allocator);
        var it = std.mem.tokenizeScalar(u8, query, ' ');
        while (it.next()) |token| try tokens.append(self.allocator, token);

        for (self.families, 0..) |family, i| {
            const rank = zf.rank(family.name, tokens.items, .{
                .case_sensitive = false,
                .plain = true,
            });
            if (rank != null) try self.filtered.append(self.allocator, i);
        }
    }

    fn up(self: *Picker, count: usize) void {
        self.current -|= count;
    }

    fn down(self: *Picker, count: usize) void {
        if (self.filtered.items.len == 0) return;
        self.current = @min(self.current + count, self.filtered.items.len - 1);
    }

    fn currentFamily(self: *const Picker) ?usize {
        if (self.current >= self.filtered.items.len) return null;
        return self.filtered.items[self.current];
    }

    pub fn update(self: *Picker, event: Event, alloc: std.mem.Allocator) !void {
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
                        if (key.matchesAny(&.{ vaxis.Key.enter, vaxis.Key.kp_enter }, .{})) {
                            if (self.currentFamily()) |idx| {
                                self.selected = self.families[idx].name;
                                self.should_quit = true;
                            }
                        }
                        if (key.matchesAny(&.{ 'x', '/' }, .{ .ctrl = true })) {
                            self.text_input.clearRetainingCapacity();
                            try self.updateFiltered();
                        }
                        if (key.matchesAny(&.{ vaxis.Key.home, vaxis.Key.kp_home, 'g' }, .{}))
                            self.current = 0;
                        if (key.matchesAny(&.{ vaxis.Key.end, vaxis.Key.kp_end, 'G' }, .{}))
                            self.current = self.filtered.items.len -| 1;
                        if (key.matchesAny(&.{ 'j', '+', vaxis.Key.down, vaxis.Key.kp_down, vaxis.Key.kp_add }, .{}))
                            self.down(1);
                        if (key.matchesAny(&.{ vaxis.Key.page_down, vaxis.Key.kp_page_down }, .{}))
                            self.down(20);
                        if (key.matches('d', .{ .ctrl = true }))
                            self.down(20);
                        if (key.matchesAny(&.{ 'k', '-', vaxis.Key.up, vaxis.Key.kp_up, vaxis.Key.kp_subtract }, .{}))
                            self.up(1);
                        if (key.matchesAny(&.{ vaxis.Key.page_up, vaxis.Key.kp_page_up }, .{}))
                            self.up(20);
                        if (key.matches('u', .{ .ctrl = true }))
                            self.up(20);
                        if (key.matches('c', .{})) {
                            if (self.currentFamily()) |idx| {
                                const line = try std.fmt.allocPrint(
                                    alloc,
                                    "font-family = \"{s}\"",
                                    .{self.families[idx].name},
                                );
                                try self.vx.copyToSystemClipboard(self.tty.writer(), line, alloc);
                            }
                        }
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
                }
            },
            .color_scheme => |scheme| try self.setColorScheme(scheme),
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
        }
    }

    /// React to the terminal switching between its light and dark scheme.
    /// With a light/dark theme pair in the config this swaps the theme.
    fn setColorScheme(self: *Picker, scheme: vaxis.Color.Scheme) !void {
        self.color_scheme = scheme;
        if (self.config) |*config| {
            const state: configpkg.ConditionalState = .{
                .theme = switch (scheme) {
                    .light => .light,
                    .dark => .dark,
                },
            };
            if (try config.changeConditionalState(state)) |new| {
                config.deinit();
                config.* = new;
            }
            self.cols = .fromConfig(config);
        } else {
            self.cols = .fallback(scheme);
        }

        // The sample image was drawn with the old colors.
        self.invalidateImage();
    }

    /// Free the sample image so it is rendered again on the next draw.
    fn invalidateImage(self: *Picker) void {
        const shown = self.shown orelse return;
        self.vx.freeImage(self.tty.writer(), shown.image.id);
        self.shown = null;
    }

    fn color(rgb: Rgb) vaxis.Color {
        return .{ .rgb = rgb };
    }

    pub fn ui_standard(self: *const Picker) vaxis.Style {
        return .{ .fg = color(self.cols.fg), .bg = color(self.cols.bg) };
    }

    pub fn ui_highlighted(self: *const Picker) vaxis.Style {
        return .{ .fg = color(self.cols.fg), .bg = color(self.cols.hover_bg) };
    }

    pub fn ui_selected(self: *const Picker) vaxis.Style {
        return .{ .fg = color(self.cols.selected_fg), .bg = color(self.cols.selected_bg) };
    }

    pub fn ui_dim(self: *const Picker) vaxis.Style {
        return .{ .fg = color(self.cols.dim), .bg = color(self.cols.bg) };
    }

    pub fn draw(self: *Picker, alloc: std.mem.Allocator) !void {
        const win = self.vx.window();
        win.clear();
        win.fill(.{ .style = self.ui_standard() });
        if (win.height == 0) return;

        self.vx.setMouseShape(.default);

        const font_list = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = @min(list_width, win.width),
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
                if (font_list.hasMouse(mouse)) |_| {
                    // NOTE: mouse co-ordinates can be negative, see the note
                    // in `+list-themes`.
                    if (mouse.button == .left and mouse.type == .release) {
                        const selection: usize = selection: {
                            var window: i32 = @min(self.window, std.math.maxInt(i32));
                            window += mouse.row;
                            break :selection @max(0, window);
                        };
                        if (selection < self.filtered.items.len) {
                            self.current = selection;
                        }
                    }
                    highlight = @max(0, mouse.row);
                }
            }
        }

        if (self.filtered.items.len == 0) {
            self.current = 0;
            self.window = 0;
        } else {
            const start = self.window;
            const end = self.window + font_list.height - 1;
            if (self.current > end)
                self.window = self.current - font_list.height + 1;
            if (self.current < start)
                self.window = self.current;
            if (self.window >= self.filtered.items.len)
                self.window = self.filtered.items.len - 1;
        }

        for (0..font_list.height) |row_capture| {
            const row: u16 = @intCast(row_capture);
            const index = self.window + row;
            if (index >= self.filtered.items.len) break;

            const family_index = self.filtered.items[index];
            const family = self.families[family_index];

            const style: enum { normal, highlighted, selected } = style: {
                if (index == self.current) break :style .selected;
                if (highlight) |h| if (h == row) break :style .highlighted;
                break :style .normal;
            };
            const row_style = switch (style) {
                .normal => self.ui_standard(),
                .highlighted => self.ui_highlighted(),
                .selected => self.ui_selected(),
            };

            // Paint the whole row so the highlight spans the list.
            if (style != .normal) {
                for (0..font_list.width) |col| {
                    _ = font_list.printSegment(
                        .{ .text = " ", .style = row_style },
                        .{ .row_offset = row, .col_offset = @intCast(col) },
                    );
                }
            }
            if (style == .selected) {
                _ = font_list.printSegment(
                    .{
                        .text = "❯ ",
                        .style = row_style,
                    },
                    .{
                        .row_offset = row,
                        .col_offset = 0,
                    },
                );
            }
            const name = font_list.printSegment(
                .{
                    .text = family.name,
                    .style = row_style,
                },
                .{
                    .row_offset = row,
                    .col_offset = 2,
                },
            );

            // Mark the font that is currently set in the user's config.
            if (self.current_font == family_index) {
                var marker = row_style;
                marker.fg = .{ .rgb = if (style == .selected) self.cols.selected_fg else self.cols.dim };
                _ = font_list.printSegment(
                    .{ .text = " ●", .style = marker },
                    .{ .row_offset = row, .col_offset = name.col },
                );
            }

            if (style == .selected) {
                _ = font_list.printSegment(
                    .{
                        .text = " ❮",
                        .style = row_style,
                    },
                    .{
                        .row_offset = row,
                        .col_offset = font_list.width -| 2,
                    },
                );
            }
        }

        try self.drawPreview(alloc, win, font_list.x_off + font_list.width);

        switch (self.mode) {
            .normal => {
                win.hideCursor();
            },
            .help => {
                win.hideCursor();
                const width = 66;
                const height: u16 = key_help.len + 3;
                const child = win.child(
                    .{
                        .x_off = win.width / 2 -| width / 2,
                        .y_off = @intCast(win.height / 2 -| height / 2),
                        .width = width,
                        .height = height,
                        .border = .{
                            .where = .all,
                            .style = self.ui_standard(),
                        },
                    },
                );

                child.fill(.{ .style = self.ui_standard() });

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
                const width = win.width -| 40;
                if (width == 0 or win.height < 5) return;
                const child = win.child(.{
                    .x_off = 20,
                    .y_off = win.height - 5,
                    .width = width,
                    .height = 3,
                    .border = .{
                        .where = .all,
                        .style = self.ui_standard(),
                    },
                });
                child.fill(.{ .style = self.ui_standard() });
                self.text_input.drawWithStyle(child, self.ui_standard());
            },
        }
    }

    pub fn drawPreview(self: *Picker, alloc: std.mem.Allocator, win: vaxis.Window, x_off_unconverted: i17) !void {
        const x_off: u16 = @intCast(x_off_unconverted);
        if (win.width <= x_off) return;
        const area = win.child(.{
            .x_off = x_off,
            .width = win.width - x_off,
            .height = win.height,
        });

        const idx = self.currentFamily() orelse {
            _ = area.printSegment(
                .{ .text = "No matching fonts.", .style = self.ui_dim() },
                .{},
            );
            return;
        };

        if (!self.vx.caps.kitty_graphics) {
            _ = area.printSegment(.{
                .text = "Preview needs a terminal with the Kitty graphics protocol.",
                .style = self.ui_dim(),
            }, .{});
            return;
        }
        // Image scaling needs the pixel size of the screen.
        if (self.vx.screen.width_pix == 0 or self.vx.screen.height_pix == 0) {
            _ = area.printSegment(.{
                .text = "Terminal didn't report its pixel size.",
                .style = self.ui_dim(),
            }, .{});
            return;
        }

        if (self.shown == null or self.shown.?.family != idx) {
            const writer = self.tty.writer();
            if (self.shown) |s| self.vx.freeImage(writer, s.image.id);
            self.shown = null;
            self.preview_failed_for = null;

            if (self.renderSample(alloc, self.families[idx].name)) |image| {
                self.shown = .{ .family = idx, .image = image };
            } else |err| {
                std.log.debug("preview failed family={s} err={}", .{ self.families[idx].name, err });
                self.preview_failed_for = idx;
            }
        }

        if (self.shown) |s| {
            // The image would be painted over the help dialog, so only
            // place it when the dialog isn't up.
            if (self.mode != .help) try s.image.draw(area, .{ .scale = .contain });
        } else if (self.preview_failed_for == idx) {
            _ = area.printSegment(.{
                .text = "Couldn't render a preview for this font.",
                .style = self.ui_dim(),
            }, .{});
        }
    }

    /// Rasterize the sample text with the given family and upload it to the
    /// terminal. All temporary memory comes from `alloc` (a per-frame arena).
    fn renderSample(
        self: *Picker,
        alloc: std.mem.Allocator,
        family: [:0]const u8,
    ) !vaxis.Image {
        var it = try self.disco.discover(alloc, .{ .family = family });
        defer it.deinit();
        var deferred = (try it.next()) orelse return error.FaceNotFound;
        defer deferred.deinit();

        var face = try deferred.load(self.lib, .{
            // xdpi/ydpi of 72 makes points == pixels.
            .size = .{ .points = sample_px, .xdpi = 72, .ydpi = 72 },
        });
        defer face.deinit();
        const metrics = font.Metrics.calc(face.getMetrics());

        // The first line is the family name so it shows in its own font,
        // followed by a blank line and the sample text.
        var lines: [sample_lines.len + 2][]const u8 = undefined;
        lines[0] = family;
        lines[1] = "";
        for (sample_lines, 2..) |line, i| lines[i] = line;

        var max_cols: usize = 0;
        for (lines) |line| {
            const cols = std.unicode.utf8CountCodepoints(line) catch line.len;
            max_cols = @max(max_cols, cols);
        }

        const width: u32 = @intCast(max_cols * metrics.cell_width + 2 * sample_padding);
        const height: u32 = @intCast(lines.len * metrics.cell_height + 2 * sample_padding);
        if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16))
            return error.SampleTooLarge;

        const fg = self.cols.fg;
        const bg = self.cols.bg;

        const pixels = try alloc.alloc(u8, width * height * 4);
        var p: usize = 0;
        while (p < pixels.len) : (p += 4) {
            pixels[p] = bg[0];
            pixels[p + 1] = bg[1];
            pixels[p + 2] = bg[2];
            pixels[p + 3] = 0xff;
        }

        var atlas = try font.Atlas.init(alloc, 1024, .grayscale);
        defer atlas.deinit(alloc);

        for (lines, 0..) |line, line_i| {
            const view = std.unicode.Utf8View.init(line) catch continue;
            var cps = view.iterator();
            var col: usize = 0;
            while (cps.nextCodepoint()) |c| : (col += 1) {
                if (c == ' ') continue;
                const gi = face.glyphIndex(c) orelse continue;
                const glyph = face.renderGlyph(alloc, &atlas, gi, .{
                    .grid_metrics = metrics,
                }) catch continue;
                if (glyph.width == 0 or glyph.height == 0) continue;

                // cell_baseline is measured up from the bottom of the cell.
                // offset_y is the distance from the baseline to the top of
                // the glyph; offset_x is the left bearing.
                const origin_x: i32 = @intCast(sample_padding + col * metrics.cell_width);
                const origin_y: i32 = @intCast(sample_padding + (line_i + 1) * metrics.cell_height - metrics.cell_baseline);
                const left = origin_x + glyph.offset_x;
                const top = origin_y - glyph.offset_y;

                for (0..glyph.height) |gy| {
                    for (0..glyph.width) |gx| {
                        const x = left + @as(i32, @intCast(gx));
                        const y = top + @as(i32, @intCast(gy));
                        if (x < 0 or y < 0 or x >= width or y >= height) continue;

                        const alpha = atlas.data[(glyph.atlas_y + gy) * atlas.size + glyph.atlas_x + gx];
                        if (alpha == 0) continue;

                        const o = (@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))) * 4;
                        inline for (0..3) |ch| {
                            const b: i32 = pixels[o + ch];
                            const f: i32 = fg[ch];
                            pixels[o + ch] = @intCast(b + @divTrunc((f - b) * alpha, 255));
                        }
                    }
                }
            }
        }

        const encoder = std.base64.standard.Encoder;
        const encoded = try alloc.alloc(u8, encoder.calcSize(pixels.len));
        _ = encoder.encode(encoded, pixels);

        return try self.vx.transmitPreEncodedImage(
            self.tty.writer(),
            encoded,
            @intCast(width),
            @intCast(height),
            .rgba,
        );
    }
};
