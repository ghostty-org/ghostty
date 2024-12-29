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

pub const gresource_xml = comptimeGenerateGResourceXML();

fn comptimeGenerateGResourceXML() []const u8 {
    comptime {
        @setEvalBranchQuota(13000);
        var counter = std.io.countingWriter(std.io.null_writer);
        try writeGResourceXML(&counter.writer());

        var buf: [counter.bytes_written]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try writeGResourceXML(stream.writer());
        const final = buf;
        return final[0..stream.getWritten().len];
    }
}

fn writeGResourceXML(writer: anytype) !void {
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<gresources>
        \\
    );
    try writer.writeAll(
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
        \\
    );
    try writer.writeAll(
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
        \\</gresources>
        \\
    );
}

pub const dependencies = deps: {
    var deps: [css_files.len + icons.len][]const u8 = undefined;
    for (css_files, 0..) |css_file, i| {
        deps[i] = std.fmt.comptimePrint("src/apprt/gtk/{s}", .{css_file});
    }
    for (icons, css_files.len..) |icon, i| {
        deps[i] = std.fmt.comptimePrint("images/icons/icon_{s}.png", .{icon.source});
    }
    break :deps deps;
};
