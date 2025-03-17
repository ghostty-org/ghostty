const std = @import("std");

pub const c = @cImport({
    @cInclude("adwaita.h");
});

const required_version = "0.16.0";

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    var it = try std.process.argsWithAllocator(alloc);
    defer it.deinit();

    _ = it.next();

    const major = try std.fmt.parseUnsigned(u8, it.next() orelse return error.NoMajorVersion, 10);
    const minor = try std.fmt.parseUnsigned(u8, it.next() orelse return error.NoMinorVersion, 10);
    const output = it.next() orelse return error.NoOutput;
    const input = it.next() orelse return error.NoInput;

    if (c.ADW_MAJOR_VERSION < major or (c.ADW_MAJOR_VERSION == major and c.ADW_MINOR_VERSION < minor)) {
        std.log.err(
            \\`libadwaita` is too old.
            \\
            \\Ghostty requires a version {d}.{d} or newer of `libadwaita` to
            \\compile this blueprint. Please install it, ensure that it is
            \\available on your PATH, and then retry building Ghostty.
        , .{ major, minor });
        std.posix.exit(1);
    }

    {
        var stdout: std.ArrayListUnmanaged(u8) = .empty;
        defer stdout.deinit(alloc);
        var stderr: std.ArrayListUnmanaged(u8) = .empty;
        defer stderr.deinit(alloc);

        var blueprint_compiler = std.process.Child.init(
            &.{
                "blueprint-compiler",
                "--version",
            },
            alloc,
        );
        blueprint_compiler.stdout_behavior = .Pipe;
        blueprint_compiler.stderr_behavior = .Pipe;
        try blueprint_compiler.spawn();
        try blueprint_compiler.collectOutput(
            alloc,
            &stdout,
            &stderr,
            std.math.maxInt(u16),
        );
        const term = blueprint_compiler.wait() catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err(
                    \\`blueprint-compiler` not found.
                    \\
                    \\Ghostty requires `blueprint-compiler` version {s} as
                    \\a build-time dependency starting from version 1.2. Please
                    \\install it, ensure that it is available on your PATH, and
                    \\then retry building Ghostty.
                    \\
                , .{required_version});
                std.posix.exit(1);
            },
            else => return err,
        };
        switch (term) {
            .Exited => |rc| {
                if (rc != 0) std.process.exit(1);
            },
            else => std.process.exit(1),
        }
        const version = std.mem.trim(u8, stdout.items, &std.ascii.whitespace);
        if (!std.mem.eql(u8, version, "0.16.0")) {
            std.log.err(
                \\`blueprint-compiler` is the wrong version.
                \\
                \\Ghostty requires `blueprint-compiler` version {s} as
                \\a build-time dependency starting from version 1.2. Please
                \\install it, ensure that it is available on your PATH, and
                \\then retry building Ghostty.
                \\
            , .{required_version});
            std.posix.exit(1);
        }
    }

    {
        var stdout: std.ArrayListUnmanaged(u8) = .empty;
        defer stdout.deinit(alloc);
        var stderr: std.ArrayListUnmanaged(u8) = .empty;
        defer stderr.deinit(alloc);

        var blueprint_compiler = std.process.Child.init(
            &.{
                "blueprint-compiler",
                "compile",
                "--output",
                output,
                input,
            },
            alloc,
        );
        blueprint_compiler.stdout_behavior = .Pipe;
        blueprint_compiler.stderr_behavior = .Pipe;
        try blueprint_compiler.spawn();
        try blueprint_compiler.collectOutput(
            alloc,
            &stdout,
            &stderr,
            std.math.maxInt(u16),
        );
        const term = blueprint_compiler.wait() catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err(
                    \\`blueprint-compiler` not found.
                    \\
                    \\Ghostty requires `blueprint-compiler` version {s} as
                    \\a build-time dependency starting from version 1.2. Please
                    \\install it, ensure that it is available on your PATH, and
                    \\then retry building Ghostty.
                    \\
                , .{required_version});
                std.posix.exit(1);
            },
            else => return err,
        };
        switch (term) {
            .Exited => |rc| {
                if (rc != 0) {
                    std.debug.print("{s}", .{stderr.items});
                    std.process.exit(1);
                }
            },
            else => {
                std.debug.print("{s}", .{stderr.items});
                std.process.exit(1);
            },
        }
    }
}
