const std = @import("std");

const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("intl", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.systemIntegrationOption("libintl", .{
        .default = !target.result.isGnuLibC(),
    })) {
        // On non-glibc platforms we don't have libintl
        // built into libc, so we have to do more work.
        // In GNU's infinite wisdom, there's no easy pkg-config file for
        // you to consume and integrate into build systems other than autoconf.
        // Users must rely on system library/include paths, or manually
        // add libintl to the Zig search path.
        module.linkSystemLibrary("intl", dynamic_link_opts);
    }

    // switch (target.result.os.tag) {
    // .windows => {
    //     const msys2 = b.dependency("libintl_msys2", .{});
    //     lib.addLibraryPath(msys2.path("usr/bin"));
    //     module.linkSystemLibrary2("msys-intl-8", .{
    //         .preferred_link_mode = .dynamic,
    //         .search_strategy = .mode_first,
    //     });
    // },
    // }
}
