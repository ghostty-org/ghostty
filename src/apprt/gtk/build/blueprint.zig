//! Checks that `libadwaita` is at least the given version and that
//! `blueprint-compiler` is on the PATH and new enough. The blueprints
//! themselves are compiled by `blueprint-compiler` directly from the build
//! system; see `gtkNgDistResources` in `src/build/SharedDeps.zig`.
//!
//! Usage: blueprint.zig <major> <minor> <stamp>
//!
//! Example: blueprint.zig 1 5 blueprint-check.stamp
//!
//! `<stamp>` is written when every check passes, so the build system has an
//! output to cache this step by.

const std = @import("std");
const adw_c = @import("adw_c");

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

const adwaita_version = std.SemanticVersion{
    .major = adw_c.ADW_MAJOR_VERSION,
    .minor = adw_c.ADW_MINOR_VERSION,
    .patch = adw_c.ADW_MICRO_VERSION,
};

const required_blueprint_version = std.SemanticVersion{
    .major = 0,
    .minor = 16,
    .patch = 0,
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    // Get our args
    var it = try init.minimal.args.iterateAllocator(alloc);
    defer it.deinit();
    _ = it.next(); // Skip argv0
    const arg_major = it.next() orelse return error.NoMajorVersion;
    const arg_minor = it.next() orelse return error.NoMinorVersion;
    const stamp = it.next() orelse return error.NoStamp;

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
            \\compile its blueprints. Please install it, ensure that it is
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
        defer {
            alloc.free(blueprint_compiler.stdout);
            alloc.free(blueprint_compiler.stderr);
        }

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

    // Everything passed.
    const file = try std.Io.Dir.cwd().createFile(init.io, stamp, .{});
    file.close(init.io);
}
