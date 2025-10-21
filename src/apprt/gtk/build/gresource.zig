//! This file contains a binary helper that builds our gresource XML
//! file that we can then use with `glib-compile-resources`.
//!
//! This binary is expected to be run from the Ghostty source root.
//! Litmus test: `src/apprt/gtk` should exist relative to the pwd.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Prefix/appid for the gresource file.
pub const prefix = "/com/mitchellh/ghostty";
pub const app_id = "com.mitchellh.ghostty";

/// The path to the Blueprint files. The folder structure is expected to be
/// `{version}/{name}.blp` where `version` is the major and minor
/// minimum adwaita version.
pub const ui_path = "src/apprt/gtk/ui";

/// The path to the CSS files.
pub const css_path = "src/apprt/gtk/css";

/// The possible icon sizes we'll embed into the gresource file.
/// If any size doesn't exist then it will be an error. We could
/// infer this completely from available files but we wouldn't be
/// able to error when they don't exist that way.
pub const icon_sizes: []const comptime_int = &.{ 16, 32, 128, 256, 512, 1024 };

/// The blueprint files that we will embed into the gresource file.
/// We can't look these up at runtime [easily] because we require the
/// compiled UI files as input. We can refactor this lator to maybe do
/// all of this automatically and ensure we have the right dependencies
/// setup in the build system.
///
/// These will be asserted to exist at runtime.
pub const blueprints: []const Blueprint = &.{
    .{ .major = 1, .minor = 0, .name = "clipboard-confirmation-dialog" },
    .{ .major = 1, .minor = 4, .name = "clipboard-confirmation-dialog" },
    .{ .major = 1, .minor = 2, .name = "close-confirmation-dialog" },
    .{ .major = 1, .minor = 2, .name = "config-errors-dialog" },
    .{ .major = 1, .minor = 2, .name = "debug-warning" },
    .{ .major = 1, .minor = 3, .name = "debug-warning" },
    .{ .major = 1, .minor = 5, .name = "imgui-widget" },
    .{ .major = 1, .minor = 5, .name = "inspector-widget" },
    .{ .major = 1, .minor = 5, .name = "inspector-window" },
    .{ .major = 1, .minor = 2, .name = "resize-overlay" },
    .{ .major = 1, .minor = 5, .name = "split-tree" },
    .{ .major = 1, .minor = 5, .name = "split-tree-split" },
    .{ .major = 1, .minor = 2, .name = "surface" },
    .{ .major = 1, .minor = 5, .name = "surface-scrolled-window" },
    .{ .major = 1, .minor = 5, .name = "surface-title-dialog" },
    .{ .major = 1, .minor = 3, .name = "surface-child-exited" },
    .{ .major = 1, .minor = 5, .name = "tab" },
    .{ .major = 1, .minor = 5, .name = "window" },
    .{ .major = 1, .minor = 5, .name = "command-palette" },
};

/// CSS files in css_path
pub const css = [_][]const u8{
    "style.css",
    "style-dark.css",
    "style-hc.css",
    "style-hc-dark.css",
};

pub const Blueprint = struct {
    major: u16,
    minor: u16,
    name: []const u8,
};

/// The list of filepaths that we depend on. Used for the build
/// system to have proper caching.
pub const file_inputs = deps: {
    const total = (icon_sizes.len * 2) + blueprints.len + css.len;
    var deps: [total][]const u8 = undefined;
    var index: usize = 0;
    for (icon_sizes) |size| {
        deps[index] = std.fmt.comptimePrint("images/gnome/{d}.png", .{size});
        deps[index + 1] = std.fmt.comptimePrint("images/gnome/{d}.png", .{size * 2});
        index += 2;
    }
    for (blueprints) |bp| {
        deps[index] = std.fmt.comptimePrint("{s}/{d}.{d}/{s}.blp", .{
            ui_path,
            bp.major,
            bp.minor,
            bp.name,
        });
        index += 1;
    }
    for (css) |name| {
        deps[index] = std.fmt.comptimePrint("{s}/{s}", .{ css_path, name });
        index += 1;
    }
    break :deps deps;
};

/// Returns the matching blueprint resource path for the given blueprint
/// definition. This will fail at compile time if the blueprint is not
/// found.
///
/// Must be called at comptime.
pub fn blueprint(comptime bp: Blueprint) [:0]const u8 {
    // The comptime block around this whole thing forces an error if
    // the caller attempts to call this function at runtime.
    comptime {
        for (blueprints) |candidate| {
            if (candidate.major == bp.major and
                candidate.minor == bp.minor and
                std.mem.eql(u8, candidate.name, bp.name))
            {
                return std.fmt.comptimePrint("{s}/ui/{d}.{d}/{s}.ui", .{
                    prefix,
                    candidate.major,
                    candidate.minor,
                    candidate.name,
                });
            }
        }

        @compileError("invalid blueprint");
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    // Collect the UI files that are passed in as arguments.
    var ui_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (ui_files.items) |item| alloc.free(item);
        ui_files.deinit(alloc);
    }
    var it = try std.process.argsWithAllocator(alloc);
    defer it.deinit();
    while (it.next()) |arg| {
        if (!std.mem.endsWith(u8, arg, ".ui")) continue;
        try ui_files.append(
            alloc,
            try alloc.dupe(u8, arg),
        );
    }

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<gresources>
        \\
    );

    try genRoot(writer);
    try genIcons(writer);
    try genUi(alloc, writer, &ui_files);

    try writer.writeAll(
        \\</gresources>
        \\
    );

    try stdout.end();
}

/// Generate the icon resources. This works by looking up all the icons
/// specified by `icon_sizes` in `images/icons/`. They are asserted to exist
/// by trying to access the file.
fn genIcons(writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}/icons">
        \\
    , .{prefix});

    const cwd = std.fs.cwd();
    inline for (icon_sizes) |size| {
        // 1x
        {
            const alias = std.fmt.comptimePrint("{d}x{d}", .{ size, size });
            const source = std.fmt.comptimePrint("images/gnome/{d}.png", .{size});
            try cwd.access(source, .{});
            try writer.print(
                \\    <file alias="{s}/apps/{s}.png">{s}</file>
                \\
            ,
                .{ alias, app_id, source },
            );
        }

        // 2x
        {
            const alias = std.fmt.comptimePrint("{d}x{d}@2", .{ size, size });
            const source = std.fmt.comptimePrint("images/gnome/{d}.png", .{size * 2});
            try cwd.access(source, .{});
            try writer.print(
                \\    <file alias="{s}/apps/{s}.png">{s}</file>
                \\
            ,
                .{ alias, app_id, source },
            );
        }
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}

/// Generate the resources at the root prefix.
fn genRoot(writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}">
        \\
    , .{prefix});

    const cwd = std.fs.cwd();
    inline for (css) |name| {
        const source = std.fmt.comptimePrint(
            "{s}/{s}",
            .{ css_path, name },
        );
        try cwd.access(source, .{});
        try writer.print(
            \\    <file compressed="true" alias="{s}">{s}</file>
            \\
        ,
            .{ name, source },
        );
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}

/// Generate all the UI resources. This works by looking up all the
/// blueprint files in `${ui_path}/{major}.{minor}/{name}.blp` and
/// assuming these will be
fn genUi(
    alloc: Allocator,
    writer: *std.Io.Writer,
    files: *const std.ArrayListUnmanaged([]const u8),
) !void {
    try writer.print(
        \\  <gresource prefix="{s}/ui">
        \\
    , .{prefix});

    for (files.items) |ui_file| {
        for (blueprints) |bp| {
            const expected = try std.fmt.allocPrint(
                alloc,
                "/{d}.{d}/{s}.ui",
                .{ bp.major, bp.minor, bp.name },
            );
            defer alloc.free(expected);
            if (!std.mem.endsWith(u8, ui_file, expected)) continue;
            try writer.print(
                "    <file compressed=\"true\" preprocess=\"xml-stripblanks\" alias=\"{d}.{d}/{s}.ui\">{s}</file>\n",
                .{ bp.major, bp.minor, bp.name, ui_file },
            );
            break;
        } else {
            // The for loop never broke which means it didn't find
            // a matching blueprint for this input.
            return error.BlueprintNotFound;
        }
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}
