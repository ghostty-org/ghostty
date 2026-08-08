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

    translate: {
        const translate_c = b.lazyImport(@This(), "translate_c") orelse break :translate;
        const translate_c_dep = b.lazyDependency("translate_c", .{}) orelse break :translate;
        const Translator = translate_c.Translator;

        const link_system_libs_full: [2]Translator.LinkSystemLib = .{
            .{ .name = "gtk4", .options = dynamic_link_opts },
            .{ .name = "gtk4-layer-shell-0", .options = dynamic_link_opts },
        };

        const headers = Translator.init(translate_c_dep, .{
            .c_source_file = b.addWriteFiles().add("c.h",
                \\#include <gtk4-layer-shell.h>
            ),
            .target = target,
            .optimize = optimize,
            .link_system_libs = if (b.systemIntegrationOption("gtk4-layer-shell", .{}))
                &link_system_libs_full
            else
                link_system_libs_full[0..1],
        });

        if (!b.systemIntegrationOption("gtk4-layer-shell", .{})) {
            // local deps (non-system layer-shell/wayland)
            const deps = try LocalDeps.get(b) orelse break :translate;
            headers.addIncludePath(deps.upstream.path("include"));
            headers.addIncludePath(deps.upstream.path("src"));
            headers.addIncludePath(deps.client_header_directory);
        }

        module.addImport("c", headers.mod);
    }

    if (!b.systemIntegrationOption("gtk4-layer-shell", .{})) {
        _ = try buildLib(b, .{ .target = target, .optimize = optimize });
    }
}

fn buildLib(b: *std.Build, options: anytype) !*std.Build.Step.Compile {
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
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    // GTK
    lib.root_module.linkSystemLibrary("gtk4", dynamic_link_opts);

    // local deps (non-system layer-shell/wayland)
    const deps = try LocalDeps.get(b) orelse return lib;
    lib.root_module.addIncludePath(deps.upstream.path("include"));
    lib.root_module.addIncludePath(deps.upstream.path("src"));
    lib.root_module.addIncludePath(deps.client_header_directory);
    for (deps.private_code_files) |source| {
        lib.root_module.addCSourceFile(.{ .file = source });
    }

    lib.installHeadersDirectory(
        deps.upstream.path("include"),
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
    lib.root_module.addCSourceFiles(.{
        .root = deps.upstream.path("src"),
        .files = srcs,
        .flags = &.{
            b.fmt("-DGTK_LAYER_SHELL_MAJOR={}", .{lib_version.major}),
            b.fmt("-DGTK_LAYER_SHELL_MINOR={}", .{lib_version.minor}),
            b.fmt("-DGTK_LAYER_SHELL_MICRO={}", .{lib_version.patch}),
        },
    });

    return lib;
}

const LocalDeps = struct {
    var cached: ?LocalDeps = null;

    upstream: *std.Build.Dependency,
    wayland_protocols: *std.Build.Dependency,
    client_header_directory: std.Build.LazyPath,
    private_code_files: []std.Build.LazyPath,

    fn init(b: *std.Build) !?LocalDeps {
        var result: LocalDeps = .{
            .upstream = b.lazyDependency("gtk4_layer_shell", .{}) orelse return null,
            .wayland_protocols = b.lazyDependency("wayland_protocols", .{}) orelse return null,
            .client_header_directory = undefined,
            .private_code_files = &.{},
        };

        // Wayland headers and source files
        {
            const protocols = [_]struct { []const u8, std.Build.LazyPath }{
                .{
                    "wlr-layer-shell-unstable-v1",
                    result.upstream.path("protocol/wlr-layer-shell-unstable-v1.xml"),
                },
                .{
                    "xdg-shell",
                    result.wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"),
                },
                // Even though we don't use session lock, we still need its headers
                .{
                    "ext-session-lock-v1",
                    result.wayland_protocols.path("staging/ext-session-lock/ext-session-lock-v1.xml"),
                },
            };

            const wf = b.addWriteFiles();
            const private_code_files = try b.allocator.alloc(std.Build.LazyPath, protocols.len);
            for (protocols, 0..) |protocol, idx| {
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
                private_code_files[idx] = source;
            }
            result.private_code_files = private_code_files;
            result.client_header_directory = wf.getDirectory();
        }

        cached = result;
        return result;
    }

    fn get(b: *std.Build) !?LocalDeps {
        if (cached) |c| return c;
        return init(b);
    }
};
