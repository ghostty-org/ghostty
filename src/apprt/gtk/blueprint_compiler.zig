const std = @import("std");

pub const c = @cImport({
    @cInclude("adwaita.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var it = try std.process.argsWithAllocator(alloc);
    defer it.deinit();

    _ = it.next();

    const major = try std.fmt.parseUnsigned(u8, it.next() orelse return error.NoMajorVersion, 10);
    const minor = try std.fmt.parseUnsigned(u8, it.next() orelse return error.NoMinorVersion, 10);
    const micro = try std.fmt.parseUnsigned(u8, it.next() orelse return error.NoMicroVersion, 10);
    const output = it.next() orelse return error.NoOutput;
    const input = it.next() orelse return error.NoInput;

    if (c.ADW_MAJOR_VERSION < major or
        (c.ADW_MAJOR_VERSION == major and c.ADW_MINOR_VERSION < minor) or
        (c.ADW_MAJOR_VERSION == major and c.ADW_MINOR_VERSION == minor and c.ADW_MICRO_VERSION < micro))
    {
        // If the Adwaita version is too old, generate an "empty" file.
        const file = try std.fs.createFileAbsolute(output, .{
            .truncate = true,
        });
        try file.writeAll(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<interface domain="com.mitchellh.ghostty"/>
        );
        defer file.close();

        return;
    }

    var compiler = std.process.Child.init(
        &.{
            "blueprint-compiler",
            "compile",
            "--output",
            output,
            input,
        },
        alloc,
    );

    const term = try compiler.spawnAndWait();
    switch (term) {
        .Exited => |rc| {
            if (rc != 0) std.posix.exit(1);
        },
        else => std.posix.exit(1),
    }
}
