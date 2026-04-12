//! Compiles a blueprint file using `blueprint-compiler`. This performs
//! additional checks to ensure that various minimum versions are met.
//!
//! Usage: blueprint.zig <major> <minor> <output> <input>
//!
//! Example: blueprint.zig 1 5 output.ui input.blp

const std = @import("std");
const adw = @import("adw");

pub const blueprint_compiler_help =
    \\
    \\When building from a Git checkout, Ghostty requires
    \\version {f} or newer of `blueprint-compiler` as a
    \\build-time dependency. Please install it, ensure that it
    \\is available on your PATH, and then retry building Ghostty.
    \\See `HACKING.md` for more details.
    \\
    \\This message should *not* appear for normal users, who
    \\should build Ghostty from official release tarballs instead.
    \\Please consult https://ghostty.org/docs/install/build for
    \\more information on the recommended build instructions.
;

const required_blueprint_version = std.SemanticVersion{
    .major = 0,
    .minor = 16,
    .patch = 0,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    // Get our args
    var it = try init.minimal.args.iterateAllocator(alloc);
    defer it.deinit();

    _ = it.next(); // Skip argv0
    const arg_major = it.next() orelse return error.NoMajorVersion;
    const arg_minor = it.next() orelse return error.NoMinorVersion;
    const output = it.next() orelse return error.NoOutput;
    const input = it.next() orelse return error.NoInput;

    const adwaita_version = std.SemanticVersion{
        .major = adw.getMajorVersion(),
        .minor = adw.getMinorVersion(),
        .patch = adw.getMicroVersion(),
    };
    const required_adwaita_version = std.SemanticVersion{
        .major = try std.fmt.parseUnsigned(u8, arg_major, 10),
        .minor = try std.fmt.parseUnsigned(u8, arg_minor, 10),
        .patch = 0,
    };
    if (adwaita_version.order(required_adwaita_version) == .lt) {
        std.debug.print(
            \\`libadwaita` is too old.
            \\
            \\Ghostty requires a version {f} or newer of `libadwaita` to
            \\compile this blueprint. Please install it, ensure that it is
            \\available on your PATH, and then retry building Ghostty.
        , .{required_adwaita_version});
        std.process.exit(1);
    }

    // Version checks
    {
        const blueprint_compiler = std.process.run(alloc, init.io, .{
            .argv = &.{ "blueprint-compiler", "--version" },
        }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print(
                    \\`blueprint-compiler` not found.
                ++ blueprint_compiler_help,
                    .{required_blueprint_version},
                );
                std.process.exit(1);
            },
            else => return err,
        };

        switch (blueprint_compiler.term) {
            .exited => |rc| if (rc != 0) std.process.exit(1),
            else => std.process.exit(1),
        }

        const version = try std.SemanticVersion.parse(std.mem.trim(
            u8,
            blueprint_compiler.stdout,
            &std.ascii.whitespace,
        ));
        if (version.order(required_blueprint_version) == .lt) {
            std.debug.print(
                \\`blueprint-compiler` is the wrong version.
            ++ blueprint_compiler_help,
                .{required_blueprint_version},
            );
            std.process.exit(1);
        }
    }

    // Compilation
    {
        const blueprint_compiler = std.process.run(alloc, init.io, .{
            .argv = &.{
                "blueprint-compiler",
                "compile",
                "--output",
                output,
                input,
            },
        }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print(
                    \\`blueprint-compiler` not found.
                ++ blueprint_compiler_help,
                    .{required_blueprint_version},
                );
                std.process.exit(1);
            },
            else => return err,
        };

        switch (blueprint_compiler.term) {
            .exited => |rc| {
                if (rc != 0) {
                    std.debug.print("{s}", .{blueprint_compiler.stderr});
                    std.process.exit(1);
                }
            },
            else => {
                std.debug.print("{s}", .{blueprint_compiler.stderr});
                std.process.exit(1);
            },
        }
    }
}
