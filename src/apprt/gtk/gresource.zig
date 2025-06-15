const std = @import("std");

const css_files = [_][]const u8{
    "style.css",
    "style-dark.css",
    "style-hc.css",
    "style-hc-dark.css",
};

const icons = [_]struct {
    alias: []const u8,
    source: []const u8,
}{
    .{
        .alias = "16x16",
        .source = "16",
    },
    .{
        .alias = "16x16@2",
        .source = "16@2x",
    },
    .{
        .alias = "32x32",
        .source = "32",
    },
    .{
        .alias = "32x32@2",
        .source = "32@2x",
    },
    .{
        .alias = "128x128",
        .source = "128",
    },
    .{
        .alias = "128x128@2",
        .source = "128@2x",
    },
    .{
        .alias = "256x256",
        .source = "256",
    },
    .{
        .alias = "256x256@2",
        .source = "256@2x",
    },
    .{
        .alias = "512x512",
        .source = "512",
    },
    .{
        .alias = "1024x1024",
        .source = "1024",
    },
};

pub const VersionedBlueprint = struct {
    major: u16,
    minor: u16,
    name: []const u8,
};

pub const blueprint_files = [_]VersionedBlueprint{
    .{ .major = 1, .minor = 5, .name = "prompt-title-dialog" },
    .{ .major = 1, .minor = 5, .name = "config-errors-dialog" },
    .{ .major = 1, .minor = 0, .name = "menu-headerbar-split_menu" },
    .{ .major = 1, .minor = 5, .name = "command-palette" },
    .{ .major = 1, .minor = 0, .name = "menu-surface-context_menu" },
    .{ .major = 1, .minor = 0, .name = "menu-window-titlebar_menu" },
    .{ .major = 1, .minor = 5, .name = "ccw-osc-52-read" },
    .{ .major = 1, .minor = 5, .name = "ccw-osc-52-write" },
    .{ .major = 1, .minor = 5, .name = "ccw-paste" },
    .{ .major = 1, .minor = 2, .name = "config-errors-dialog" },
    .{ .major = 1, .minor = 2, .name = "ccw-osc-52-read" },
    .{ .major = 1, .minor = 2, .name = "ccw-osc-52-write" },
    .{ .major = 1, .minor = 2, .name = "ccw-paste" },
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    var extra_ui_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (extra_ui_files.items) |item| alloc.free(item);
        extra_ui_files.deinit(alloc);
    }

    var it = try std.process.argsWithAllocator(alloc);
    defer it.deinit();

    while (it.next()) |argument| {
        if (std.mem.eql(u8, std.fs.path.extension(argument), ".ui")) {
            try extra_ui_files.append(alloc, try alloc.dupe(u8, argument));
        }
    }

    const writer = std.io.getStdOut().writer();

    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<gresources>
        \\  <gresource prefix="/com/mitchellh/ghostty">
        \\
    );
    for (css_files) |css_file| {
        try writer.print(
            "    <file compressed=\"true\" alias=\"{s}\">src/apprt/gtk/{s}</file>\n",
            .{ css_file, css_file },
        );
    }
    try writer.writeAll(
        \\  </gresource>
        \\  <gresource prefix="/com/mitchellh/ghostty/icons">
        \\
    );
    for (icons) |icon| {
        try writer.print(
            "    <file alias=\"{s}/apps/com.mitchellh.ghostty.png\">images/icons/icon_{s}.png</file>\n",
            .{ icon.alias, icon.source },
        );
    }
    try writer.writeAll(
        \\  </gresource>
        \\  <gresource prefix="/com/mitchellh/ghostty/ui">
        \\
    );
    for (extra_ui_files.items) |ui_file| {
        for (blueprint_files) |file| {
            const expected = try std.fmt.allocPrint(alloc, "/{d}.{d}/{s}.ui", .{ file.major, file.minor, file.name });
            defer alloc.free(expected);
            if (!std.mem.endsWith(u8, ui_file, expected)) continue;
            try writer.print(
                "    <file compressed=\"true\" preprocess=\"xml-stripblanks\" alias=\"{d}.{d}/{s}.ui\">{s}</file>\n",
                .{ file.major, file.minor, file.name, ui_file },
            );
            break;
        } else return error.BlueprintNotFound;
    }
    try writer.writeAll(
        \\  </gresource>
        \\</gresources>
        \\
    );
}

pub const dependencies = deps: {
    const total = css_files.len + icons.len + blueprint_files.len;
    var deps: [total][]const u8 = undefined;
    var index: usize = 0;
    for (css_files) |css_file| {
        deps[index] = std.fmt.comptimePrint("src/apprt/gtk/{s}", .{css_file});
        index += 1;
    }
    for (icons) |icon| {
        deps[index] = std.fmt.comptimePrint("images/icons/icon_{s}.png", .{icon.source});
        index += 1;
    }
    for (blueprint_files) |blueprint_file| {
        deps[index] = std.fmt.comptimePrint("src/apprt/gtk/ui/{d}.{d}/{s}.blp", .{
            blueprint_file.major,
            blueprint_file.minor,
            blueprint_file.name,
        });
        index += 1;
    }
    break :deps deps;
};
