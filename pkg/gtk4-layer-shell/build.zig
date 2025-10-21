const std = @import("std");

const version = @import("build.zig.zon").version;

const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig API
    const module = b.addModule("gtk4-layer-shell", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Needs the gtk.h header
    module.linkSystemLibrary("gtk4", dynamic_link_opts);

    if (b.systemIntegrationOption("gtk4-layer-shell", .{})) {
        module.linkSystemLibrary("gtk4-layer-shell-0", dynamic_link_opts);
    } else {
        _ = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,
        });
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const lib_version = try std.SemanticVersion.parse(version);
    const target = options.target;
    const optimize = options.optimize;

    // Shared library
    const lib = b.addLibrary(.{
        .name = "gtk4-layer-shell",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // We need to call both lazy dependencies to tell Zig we need both
    const upstream_ = b.lazyDependency("gtk4_layer_shell", .{});
    const wayland_protocols_ = b.lazyDependency("wayland_protocols", .{});
    const upstream = upstream_ orelse return lib;
    const wayland_protocols = wayland_protocols_ orelse return lib;

    lib.linkLibC();
    lib.addIncludePath(upstream.path("include"));
    lib.addIncludePath(upstream.path("src"));
    module.addIncludePath(upstream.path("include"));

    // GTK
    lib.linkSystemLibrary2("gtk4", dynamic_link_opts);

    // Wayland headers and source files
    {
        const protocols = [_]struct { []const u8, std.Build.LazyPath }{
            .{
                "wlr-layer-shell-unstable-v1",
                upstream.path("protocol/wlr-layer-shell-unstable-v1.xml"),
            },
            .{
                "xdg-shell",
                wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"),
            },
            // Even though we don't use session lock, we still need its headers
            .{
                "ext-session-lock-v1",
                wayland_protocols.path("staging/ext-session-lock/ext-session-lock-v1.xml"),
            },
        };

        const wf = b.addWriteFiles();
        for (protocols) |protocol| {
            const name, const xml = protocol;

            const header_scanner = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
            header_scanner.addFileArg(xml);
            _ = wf.addCopyFile(
                header_scanner.addOutputFileArg(name),
                b.fmt("{s}-client.h", .{name}),
            );

            const source_scanner = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
            source_scanner.addFileArg(xml);
            const source = source_scanner.addOutputFileArg(b.fmt("{s}.c", .{name}));
            lib.addCSourceFile(.{ .file = source });
        }
        lib.addIncludePath(wf.getDirectory());
    }

    lib.installHeadersDirectory(
        upstream.path("include"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    // Certain files relating to session lock were removed as we don't use them
    const srcs: []const []const u8 = &.{
        "gtk4-layer-shell.c",
        "layer-surface.c",
        "libwayland-shim.c",
        "registry.c",
        "stolen-from-libwayland.c",
        "stubbed-surface.c",
        "xdg-surface-server.c",
    };
    lib.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = srcs,
        .flags = &.{
            b.fmt("-DGTK_LAYER_SHELL_MAJOR={}", .{lib_version.major}),
            b.fmt("-DGTK_LAYER_SHELL_MINOR={}", .{lib_version.minor}),
            b.fmt("-DGTK_LAYER_SHELL_MICRO={}", .{lib_version.patch}),
        },
    });

    return lib;
}
