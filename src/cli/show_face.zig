const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// The codepoint to search for.
    cp: ?u21 = null,

    /// Search for all of the codepoints in the string.
    string: ?[]const u8 = null,

    /// Font style to search for.
    style: font.Style = .regular,

    /// If specified, force text or emoji presentation.
    presentation: ?font.Presentation = null,

    // Enable arg parsing diagnostics so that we don't get an error if
    // there is a "normal" config setting on the cli.
    _diagnostics: diagnostics.DiagnosticList = .{},

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

/// The `show-face` command shows what font face Ghostty will use to render a
/// specific codepoint. Note that this command does not take into consideration
/// grapheme clustering or any other Unicode features that might modify the
/// presentation of a codepoint, so this may show a different font face than
/// Ghostty uses to render a codepoint in a terminal session.
///
/// Flags:
///
///   * `--cp`: Find the face for a single codepoint. The codepoint may be specified
///     in decimal (`--cp=65`), hexadecimal (`--cp=0x41`), octal (`--cp=0o101`), or
///     binary (`--cp=0b1000001`).
///
///   * `--string`: Find the face for all of the codepoints in a string. The
///     string must be a valid UTF-8 sequence.
///
///   * `--style`: Search for a specific style. Valid options are `regular`, `bold`,
///     `italic`, and `bold_italic`.
///
///   * `--presentation`: If set, force searching for a specific presentation
///     style. Valid options are `text` and `emoji`. If unset, the presentation
///     style of a codepoint will be inferred from the Unicode standard.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // Its possible to build Ghostty without font discovery!
    if (comptime font.Discover == void) {
        try stderr.print(
            \\Ghostty was built without a font discovery mechanism. This is a compile-time
            \\option. Please review how Ghostty was built from source, contact the
            \\maintainer to enable a font discovery mechanism, and try again.
        ,
            .{},
        );
        return 1;
    }

    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    // Print out any diagnostics, unless it's likely that the diagnostic was
    // generated trying to parse a "normal" configuration setting. Exit with an
    // error code if any diagnostics were printed.
    if (!opts._diagnostics.empty()) {
        var exit: bool = false;
        outer: for (opts._diagnostics.items()) |diagnostic| {
            if (diagnostic.location != .cli) continue :outer;
            inner: inline for (@typeInfo(Options).@"struct".fields) |field| {
                if (field.name[0] == '_') continue :inner;
                if (std.mem.eql(u8, field.name, diagnostic.key)) {
                    try stderr.writeAll("config error: ");
                    try diagnostic.write(stderr);
                    try stderr.writeAll("\n");
                    exit = true;
                }
            }
        }
        if (exit) return 1;
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (opts.cp == null and opts.string == null) {
        try stderr.print("You must specify a codepoint with --cp or a string with --string\n", .{});
        return 1;
    }

    var config = Config.load(alloc) catch |err| {
        try stderr.print("Unable to load config: {}", .{err});
        return 1;
    };
    defer config.deinit();

    // Print out any diagnostics generated from parsing the config, unless
    // the diagnostic might have been generated because it's actually an
    // action-specific argument.
    if (!config._diagnostics.empty()) {
        outer: for (config._diagnostics.items()) |diagnostic| {
            inner: inline for (@typeInfo(Options).@"struct".fields) |field| {
                if (field.name[0] == '_') continue :inner;
                if (std.mem.eql(u8, field.name, diagnostic.key) and (diagnostic.location == .none or diagnostic.location == .cli)) continue :outer;
            }
            try stderr.writeAll("config error: ");
            try diagnostic.write(stderr);
            try stderr.writeAll("\n");
        }
    }

    var font_grid_set = font.SharedGridSet.init(alloc) catch |err| {
        try stderr.print("Unable to initialize font grid set: {}", .{err});
        return 1;
    };
    errdefer font_grid_set.deinit();

    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = 96,
        .ydpi = 96,
    };

    var font_config = font.SharedGridSet.DerivedConfig.init(alloc, config) catch |err| {
        try stderr.print("Unable to initialize font config: {}", .{err});
        return 1;
    };

    const font_grid_key, const font_grid = font_grid_set.ref(
        &font_config,
        font_size,
    ) catch |err| {
        try stderr.print("Unable to get font grid: {}", .{err});
        return 1;
    };
    defer font_grid_set.deref(font_grid_key);

    if (opts.cp) |cp| {
        if (try lookup(alloc, stdout, stderr, font_grid, opts.style, opts.presentation, cp)) |rc| return rc;
    }
    if (opts.string) |string| {
        const view = std.unicode.Utf8View.init(string) catch |err| {
            try stderr.print("Unable to parse string as unicode: {}", .{err});
            return 1;
        };
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (try lookup(alloc, stdout, stderr, font_grid, opts.style, opts.presentation, cp)) |rc| return rc;
        }
    }

    return 0;
}

fn lookup(
    alloc: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    font_grid: *font.SharedGrid,
    style: font.Style,
    presentation: ?font.Presentation,
    cp: u21,
) !?u8 {
    const idx = font_grid.resolver.getIndex(alloc, cp, style, presentation) orelse {
        try stdout.print("U+{0X:0>2} « {0u} » not found.\n", .{cp});
        return null;
    };

    const face = font_grid.resolver.collection.getFace(idx) catch |err| switch (err) {
        error.SpecialHasNoFace => {
            try stdout.print("U+{0X:0>2} « {0u} » is handled by Ghostty's internal sprites.\n", .{cp});
            return null;
        },
        else => {
            try stderr.print("Unable to get face: {}", .{err});
            return 1;
        },
    };

    var buf: [1024]u8 = undefined;
    const name = face.name(&buf) catch |err| {
        try stderr.print("Unable to get name of face: {}", .{err});
        return 1;
    };

    try stdout.print("U+{0X:0>2} « {0u} » found in face “{1s}”.\n", .{ cp, name });

    return null;
}
