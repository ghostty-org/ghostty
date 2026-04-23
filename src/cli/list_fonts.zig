const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const font = @import("../font/main.zig");

const log = std.log.scoped(.list_fonts);

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// The font family to search for. If this is set, then only fonts
    /// matching this family will be listed.
    family: ?[:0]const u8 = null,

    /// The style name to search for.
    style: ?[:0]const u8 = null,

    /// Font styles to search for. If this is set, then only fonts that
    /// match the given styles will be listed.
    bold: bool = false,
    italic: bool = false,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-fonts` command is used to list all the available fonts for
/// Ghostty. This uses the exact same font discovery mechanism Ghostty uses to
/// find fonts to use.
///
/// When executed with no arguments, this will list all available fonts, sorted
/// by family name, then font name. If a family name is given with `--family`,
/// the sorting will be disabled and the results instead will be shown in the
/// same priority order Ghostty would use to pick a font.
///
/// Flags:
///
///   * `--bold`: Filter results to specific bold styles. It is not guaranteed
///     that only those styles are returned. They are only prioritized.
///
///   * `--italic`: Filter results to specific italic styles. It is not guaranteed
///     that only those styles are returned. They are only prioritized.
///
///   * `--style`: Filter results based on the style string advertised by a font.
///     It is not guaranteed that only those styles are returned. They are only
///     prioritized.
///
///   * `--family`: Filter results to a specific font family. The family handling
///     is identical to the `font-family` set of Ghostty configuration values, so
///     this can be used to debug why your desired font may not be loading.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    var config: Options = .{};
    defer config.deinit();
    try args.parse(Options, alloc_gpa, &config, argsIter);

    // Use an arena for all our memory allocs
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Its possible to build Ghostty without font discovery!
    if (comptime font.Discover == void) {
        // On Windows, scan the system font directory directly using FreeType.
        if (comptime builtin.os.tag == .windows) {
            return try listWindowsFonts(alloc_gpa, alloc, config);
        }

        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print(
            \\Ghostty was built without a font discovery mechanism. This is a compile-time
            \\option. Please review how Ghostty was built from source, contact the
            \\maintainer to enable a font discovery mechanism, and try again.
        ,
            .{},
        );
        try stderr.flush();
        return 1;
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;

    // We'll be putting our fonts into a list categorized by family
    // so it is easier to read the output.
    var families: std.ArrayList([]const u8) = .empty;
    var map: std.StringHashMap(std.ArrayListUnmanaged([]const u8)) = .init(alloc);

    // Look up all available fonts
    var disco = font.Discover.init();
    defer disco.deinit();
    var disco_it = try disco.discover(alloc, .{
        .family = config.family,
        .style = config.style,
        .bold = config.bold,
        .italic = config.italic,
        .monospace = config.family == null,
    });
    defer disco_it.deinit();
    while (try disco_it.next()) |face| {
        var buf: [1024]u8 = undefined;

        const family_buf = face.familyName(&buf) catch |err| {
            log.err("failed to get font family name: {}", .{err});
            continue;
        };
        const family = try alloc.dupe(u8, family_buf);

        const full_name_buf = face.name(&buf) catch |err| {
            log.err("failed to get font name: {}", .{err});
            continue;
        };
        const full_name = try alloc.dupe(u8, full_name_buf);

        const gop = try map.getOrPut(family);
        if (!gop.found_existing) {
            try families.append(alloc, family);
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(alloc, full_name);
    }

    // Sort our keys.
    if (config.family == null) {
        std.mem.sortUnstable([]const u8, families.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);
    }

    // Output each
    for (families.items) |family| {
        const list = map.get(family) orelse continue;
        if (list.items.len == 0) continue;
        if (config.family == null) {
            std.mem.sortUnstable([]const u8, list.items, {}, struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.lessThan);
        }

        try stdout.print("{s}\n", .{family});
        for (list.items) |item| try stdout.print("  {s}\n", .{item});
        try stdout.print("\n", .{});
    }

    try stdout.flush();
    return 0;
}

/// List fonts on Windows by scanning font directories directly with FreeType.
fn listWindowsFonts(alloc_gpa: Allocator, alloc: Allocator, config: Options) !u8 {
    _ = alloc_gpa;

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var families: std.ArrayList([]const u8) = .empty;
    var map: std.StringHashMap(std.ArrayListUnmanaged([]const u8)) = .init(alloc);

    // Scan system fonts directory (%SystemRoot%\Fonts, typically C:\Windows\Fonts)
    if (std.process.getEnvVarOwned(alloc, "SystemRoot")) |windir| {
        defer alloc.free(windir);
        const sys_path = try std.fmt.allocPrintSentinel(alloc, "{s}\\Fonts", .{windir}, 0);
        defer alloc.free(sys_path);
        try scanWindowsFontDir(alloc, &lib, sys_path, config, &families, &map);
    } else |_| {}

    // Scan user-installed fonts directory (%LOCALAPPDATA%\Microsoft\Windows\Fonts)
    if (std.process.getEnvVarOwned(alloc, "LOCALAPPDATA")) |local_appdata| {
        defer alloc.free(local_appdata);
        const user_path = try std.fmt.allocPrintSentinel(alloc, "{s}\\Microsoft\\Windows\\Fonts", .{local_appdata}, 0);
        defer alloc.free(user_path);
        try scanWindowsFontDir(alloc, &lib, user_path, config, &families, &map);
    } else |_| {}

    // Sort families
    std.mem.sortUnstable([]const u8, families.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    for (families.items) |family| {
        const list = map.get(family) orelse continue;
        if (list.items.len == 0) continue;
        try stdout.print("{s}\n", .{family});
        for (list.items) |item| try stdout.print("  {s}\n", .{item});
        try stdout.print("\n", .{});
    }

    try stdout.flush();
    return 0;
}

fn scanWindowsFontDir(
    alloc: Allocator,
    lib: *font.Library,
    dir_path: [:0]const u8,
    config: Options,
    families: *std.ArrayList([]const u8),
    map: *std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
) !void {
    var dir = std.fs.openDirAbsoluteZ(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        const is_font = std.mem.endsWith(u8, name, ".ttf") or
            std.mem.endsWith(u8, name, ".ttc") or
            std.mem.endsWith(u8, name, ".otf") or
            std.mem.endsWith(u8, name, ".TTF") or
            std.mem.endsWith(u8, name, ".TTC") or
            std.mem.endsWith(u8, name, ".OTF");
        if (!is_font) continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrintZ(&path_buf, "{s}\\{s}", .{ dir_path, name }) catch continue;

        var face_index: i32 = 0;
        while (face_index < 16) : (face_index += 1) {
            var face = font.Face.initFile(
                lib.*,
                full_path,
                face_index,
                .{ .size = .{ .points = 12 } },
            ) catch break;
            defer face.deinit();

            const ft_family: ?[*:0]const u8 = face.face.handle.*.family_name;
            if (ft_family == null) {
                if (std.mem.endsWith(u8, name, ".ttc") or std.mem.endsWith(u8, name, ".TTC")) continue;
                break;
            }
            const family_raw = std.mem.span(ft_family.?);

            if (config.family) |filter| {
                if (std.ascii.indexOfIgnoreCase(family_raw, filter) == null) {
                    if (std.mem.endsWith(u8, name, ".ttc") or std.mem.endsWith(u8, name, ".TTC")) continue;
                    break;
                }
            }

            const family = try alloc.dupe(u8, family_raw);
            const gop = try map.getOrPut(family);
            if (!gop.found_existing) {
                try families.append(alloc, family);
                gop.value_ptr.* = .{};
            }

            const ft_style: ?[*:0]const u8 = face.face.handle.*.style_name;
            const style = if (ft_style) |s| std.mem.span(s) else "Regular";
            const full_name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ family, style });
            try gop.value_ptr.append(alloc, full_name);

            if (!std.mem.endsWith(u8, name, ".ttc") and !std.mem.endsWith(u8, name, ".TTC")) break;
        }
    }
}
