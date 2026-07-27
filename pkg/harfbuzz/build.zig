const std = @import("std");
const apple_sdk = @import("apple_sdk");

const root_build_container = @This();

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coretext_enabled = b.option(bool, "enable-coretext", "Build coretext") orelse false;
    const freetype_enabled = b.option(bool, "enable-freetype", "Build freetype") orelse true;

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    });

    const module = harfbuzz: {
        const module = b.addModule("harfbuzz", .{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = if (target.result.os.tag.isDarwin())
                &.{
                    .{ .name = "freetype", .module = freetype.module("freetype") },
                    .{
                        .name = "macos",
                        .module = b.dependency("macos", .{ .target = target, .optimize = optimize })
                            .module("macos"),
                    },
                }
            else
                &.{
                    .{ .name = "freetype", .module = freetype.module("freetype") },
                },
        });

        try HarfBuzzC.addImportToModule(b, module, .{
            .target = target,
            .optimize = optimize,
            .harfbuzz = if (b.systemIntegrationOption("harfbuzz", .{})) .{ .dynamic = dynamic_link_opts } else .static,
            .coretext = coretext_enabled,
            .freetype = if (freetype_enabled) ft: {
                break :ft if (b.systemIntegrationOption("freetype", .{}))
                    .{ .dynamic = dynamic_link_opts }
                else
                    .static;
            } else null,
        });

        const options = b.addOptions();
        options.addOption(bool, "coretext", coretext_enabled);
        options.addOption(bool, "freetype", freetype_enabled);
        module.addOptions("build_options", options);
        break :harfbuzz module;
    };

    const test_exe = b.addTest(.{
        .name = "test",
        .root_module = module,
    });

    const tests_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);

    if (!b.systemIntegrationOption("harfbuzz", .{})) {
        const lib = try buildLib(b, .{
            .target = target,
            .optimize = optimize,

            .coretext_enabled = coretext_enabled,
            .freetype_enabled = freetype_enabled,

            .dynamic_link_opts = dynamic_link_opts,
        });

        test_exe.root_module.linkLibrary(lib);
    }
}

fn buildLib(b: *std.Build, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const coretext_enabled = options.coretext_enabled;
    const freetype_enabled = options.freetype_enabled;

    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    });

    const lib = b.addLibrary(.{
        .name = "harfbuzz",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // On MSVC, we must not use linkLibCpp because Zig unconditionally
            // passes -nostdinc++ and then adds its bundled libc++/libc++abi
            // include paths, which conflict with MSVC's own C++ runtime
            // headers. The MSVC SDK include directories (added via linkLibC)
            // contain both C and C++ headers, so linkLibCpp is not needed.
            .link_libcpp = target.result.abi != .msvc,
        }),
        .linkage = .static,
    });

    if (target.result.os.tag.isDarwin()) {
        try apple_sdk.addPaths(b, lib);
    }

    const dynamic_link_opts = options.dynamic_link_opts;

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-DHAVE_STDBOOL_H",
    });
    // Disable ubsan for MSVC: Zig's ubsan runtime cannot be bundled
    // on Windows (LNK4229), leaving __ubsan_handle_* unresolved when
    // the static archive is consumed by an external linker.
    if (target.result.abi == .msvc) {
        try flags.appendSlice(b.allocator, &.{
            "-fno-sanitize=undefined",
            "-fno-sanitize-trap=undefined",
        });
    }
    if (target.result.os.tag != .windows) {
        try flags.appendSlice(b.allocator, &.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
        });
    }

    // Freetype
    _ = b.systemIntegrationOption("freetype", .{}); // So it shows up in help
    if (freetype_enabled) {
        try flags.appendSlice(b.allocator, &.{
            "-DHAVE_FREETYPE=1",

            // Let's just assume a new freetype
            "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_DONE_MM_VAR=1",
            "-DHAVE_FT_GET_TRANSFORM=1",
        });

        if (b.systemIntegrationOption("freetype", .{})) {
            lib.root_module.linkSystemLibrary("freetype2", dynamic_link_opts);
        } else {
            lib.root_module.linkLibrary(freetype.artifact("freetype"));
        }
    }

    if (coretext_enabled) {
        try flags.appendSlice(b.allocator, &.{"-DHAVE_CORETEXT=1"});
        lib.root_module.linkFramework("CoreText", .{});
    }

    if (b.lazyDependency("harfbuzz", .{})) |upstream| {
        lib.root_module.addIncludePath(upstream.path("src"));
        lib.root_module.addCSourceFile(.{
            .file = upstream.path("src/harfbuzz.cc"),
            .flags = flags.items,
        });
        lib.installHeadersDirectory(
            upstream.path("src"),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    return lib;
}

const HarfBuzzC = struct {
    const AddImportToModuleOptions = struct {
        const LinkMode = union(enum) {
            static,
            dynamic: std.Build.Module.LinkSystemLibraryOptions,
        };

        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        harfbuzz: LinkMode,
        coretext: bool,
        freetype: ?LinkMode,
    };

    fn fmtInclude(w: *std.Io.Writer, name: []const u8, mode: AddImportToModuleOptions.LinkMode) !void {
        if (mode == .dynamic) {
            try w.print("#include <{s}>\n", .{name});
        } else {
            try w.print("#include \"{s}\"\n", .{name});
        }
    }

    fn addImportToModule(
        b: *std.Build,
        module: *std.Build.Module,
        options: AddImportToModuleOptions,
    ) !void {
        // TODO: There's a decent amount of duplication here right now.
        // Basically we want to mirror what we're passing in buildLib to make
        // sure that the translation is generated as correct as possible.
        // Eventually, we want to try and unravel this as much as we can, to
        // the point that ultimately all C flags and even link options are
        // self-contained in the translation artifact.
        //
        // This is a bit tricky right now as there are situations where we
        // provide a static library built straight off of the C file, hence the
        // duplication.
        //
        // NOTE: This function de-allocates nothing as b.allocator is an arena
        // (unfortunately not documented, but a cursory search in various
        // communities or the issue trackers should turn up confirmation).

        const translate_c = b.lazyImport(root_build_container, "translate_c") orelse return;
        const translate_c_dep = b.lazyDependency("translate_c", .{}) orelse return;

        const c_source = c_source: {
            var source_builder: std.Io.Writer.Allocating = .init(b.allocator);
            try fmtInclude(&source_builder.writer, "hb.h", options.harfbuzz);

            if (options.coretext) {
                try fmtInclude(&source_builder.writer, "hb-coretext.h", options.harfbuzz);
            }

            if (options.freetype != null) {
                try fmtInclude(&source_builder.writer, "hb-ft.h", options.harfbuzz);
            }

            break :c_source source_builder.written();
        };

        // Assemble system libs
        const system_libs = libs: {
            var libs_builder: std.ArrayList(translate_c.Translator.LinkSystemLib) = .empty;
            if (options.harfbuzz == .dynamic)
                try libs_builder.append(b.allocator, .{ .name = "harfbuzz", .options = options.harfbuzz.dynamic });
            if (options.freetype) |ft| {
                if (ft == .dynamic)
                    try libs_builder.append(b.allocator, .{ .name = "freetype2", .options = ft.dynamic });
            }

            break :libs libs_builder.items;
        };

        // Assemble flags
        const flags = flags: {
            var flag_builder: std.ArrayList([]const u8) = .empty;
            try flag_builder.appendSlice(b.allocator, &.{
                "-DHAVE_STDBOOL_H",
            });
            // Disable ubsan for MSVC: Zig's ubsan runtime cannot be bundled
            // on Windows (LNK4229), leaving __ubsan_handle_* unresolved when
            // the static archive is consumed by an external linker.
            if (options.target.result.abi == .msvc) {
                try flag_builder.appendSlice(b.allocator, &.{
                    "-fno-sanitize=undefined",
                    "-fno-sanitize-trap=undefined",
                });
            }
            if (options.target.result.os.tag != .windows) {
                try flag_builder.appendSlice(b.allocator, &.{
                    "-DHAVE_UNISTD_H",
                    "-DHAVE_SYS_MMAN_H",
                    "-DHAVE_PTHREAD=1",
                });
            }

            // Freetype flags/non-system include paths
            if (options.freetype != null) {
                try flag_builder.appendSlice(b.allocator, &.{
                    "-DHAVE_FREETYPE=1",

                    // Let's just assume a new freetype
                    "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
                    "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
                    "-DHAVE_FT_DONE_MM_VAR=1",
                    "-DHAVE_FT_GET_TRANSFORM=1",
                });
            }

            // Coretext
            if (options.coretext) {
                try flag_builder.appendSlice(b.allocator, &.{"-DHAVE_CORETEXT=1"});
                try flag_builder.appendSlice(b.allocator, &.{"-fblocks"});
            }

            break :flags flag_builder.items;
        };

        const hb_c: translate_c.Translator = .init(translate_c_dep, .{
            .c_source_file = b.addWriteFiles().add(
                "hb_c.h",
                c_source,
            ),
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
            .link_system_libs = system_libs,
            .libc_file = if (options.target.result.os.tag.isDarwin()) libc_file: {
                switch (try @import("apple_sdk").pathsForTarget(b, options.target.result)) {
                    inline else => |paths| break :libc_file paths.libc,
                }
            } else null,
            .extra_args = flags,
        });

        if (options.harfbuzz == .static) {
            if (b.lazyDependency("harfbuzz", .{})) |upstream| {
                hb_c.addIncludePath(upstream.path("src"));
            }
        }

        // Freetype non-system include paths
        if (options.freetype) |freetype_enabled| {
            if (freetype_enabled == .static) {
                const ft_dep = b.dependency("freetype", .{
                    .target = options.target,
                    .optimize = options.optimize,
                    .@"enable-libpng" = true,
                });

                if (ft_dep.builder.lazyDependency(
                    "freetype",
                    .{},
                )) |freetype_lazy_dep| {
                    hb_c.addIncludePath(freetype_lazy_dep.path("include"));
                }
            }
        }

        // Coretext
        if (options.coretext) {
            // NOTE: We should not necessarily need to add this directly to C
            // translation, so we just add it to the module.
            hb_c.mod.linkFramework("CoreText", .{});
        }

        module.addImport("hb_c", hb_c.mod);
    }
};
