const std = @import("std");
const apple_sdk = @import("apple_sdk");
const translate_c = @import("translate_c");

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

    const freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    });

    const harfbuzz_c_builder: HarfBuzzC = .{
        .builder = b,
        .options = .{
            .target = target,
            .optimize = optimize,
            .harfbuzz = if (b.systemIntegrationOption("harfbuzz", .{}))
                .{ .dynamic = dynamic_link_opts }
            else
                .static,
            .coretext = coretext_enabled,
            .freetype = if (freetype_enabled)
                .{
                    .dependency = freetype_dep,
                    .link_mode = if (b.systemIntegrationOption("freetype", .{}))
                        .{ .dynamic = dynamic_link_opts }
                    else
                        .static,
                }
            else
                null,
        },
    };

    const module = harfbuzz: {
        const module = b.addModule("harfbuzz", .{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = if (target.result.os.tag.isDarwin())
                &.{
                    .{ .name = "freetype", .module = freetype_dep.module("freetype") },
                    .{
                        .name = "macos",
                        .module = b.dependency("macos", .{ .target = target, .optimize = optimize })
                            .module("macos"),
                    },
                }
            else
                &.{
                    .{ .name = "freetype", .module = freetype_dep.module("freetype") },
                },
        });

        try harfbuzz_c_builder.addImportToModule(module);

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
        const lib = try harfbuzz_c_builder.buildLib();
        test_exe.root_module.linkLibrary(lib);
    }
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
        freetype: ?struct {
            dependency: *std.Build.Dependency,
            link_mode: LinkMode,
        },
    };

    builder: *std.Build,
    options: AddImportToModuleOptions,

    fn appendInclude(
        list: *std.ArrayList(translate_c.Options.IncludeFile),
        name: []const u8,
        mode: AddImportToModuleOptions.LinkMode,
    ) void {
        list.appendAssumeCapacity(.{
            .path = name,
            .type = switch (mode) {
                .static => .user,
                .dynamic => .system,
            },
        });
    }

    fn includeFiles(self: *const HarfBuzzC) ![]translate_c.Options.IncludeFile {
        var len: usize = 1;
        if (self.options.coretext) len += 1;
        if (self.options.freetype != null) len += 1;
        var includes_builder: std.ArrayList(translate_c.Options.IncludeFile) =
            try .initCapacity(self.builder.allocator, len);

        appendInclude(&includes_builder, "hb.h", self.options.harfbuzz);
        if (self.options.coretext) appendInclude(&includes_builder, "hb-coretext.h", self.options.harfbuzz);
        if (self.options.freetype != null) appendInclude(&includes_builder, "hb-ft.h", self.options.harfbuzz);

        return includes_builder.items;
    }

    fn systemLibs(self: *const HarfBuzzC) ![][]const u8 {
        var len: usize = 1;
        if (self.options.harfbuzz == .dynamic) len += 1;
        if (self.options.freetype != null and self.options.freetype.?.link_mode == .dynamic) len += 1;
        var libs_builder: std.ArrayList([]const u8) = try .initCapacity(self.builder.allocator, len);

        if (self.options.harfbuzz == .dynamic)
            libs_builder.appendAssumeCapacity("harfbuzz");
        if (self.options.freetype != null and self.options.freetype.?.link_mode == .dynamic)
            libs_builder.appendAssumeCapacity("freetype2");

        return libs_builder.items;
    }

    fn includePaths(self: *const HarfBuzzC) ![]std.Build.LazyPath {
        const hb_upstream: ?*std.Build.Dependency = if (self.options.harfbuzz == .static)
            self.builder.lazyDependency("harfbuzz", .{})
        else
            null;

        const ft_upstream: ?*std.Build.Dependency =
            if (self.options.freetype) |ft| ft: {
                if (ft.link_mode == .static) break :ft ft.dependency.builder.lazyDependency("freetype", .{});
                break :ft null;
            } else null;

        var len: usize = 0;
        if (hb_upstream != null) len += 1;
        if (ft_upstream != null) len += 1;
        var paths_builder: std.ArrayList(std.Build.LazyPath) = try .initCapacity(self.builder.allocator, len);

        if (hb_upstream) |upstream| paths_builder.appendAssumeCapacity(upstream.path("src"));
        if (ft_upstream) |upstream| paths_builder.appendAssumeCapacity(upstream.path("include"));

        return paths_builder.items;
    }

    fn frameworks(self: *const HarfBuzzC) []const []const u8 {
        return if (self.options.coretext) &.{"CoreText"} else &.{};
    }

    fn flags(self: *const HarfBuzzC) ![][]const u8 {
        var flag_builder: std.ArrayList([]const u8) = .empty;
        try flag_builder.appendSlice(self.builder.allocator, &.{
            "-DHAVE_STDBOOL_H",
        });
        // Disable ubsan for MSVC: Zig's ubsan runtime cannot be bundled
        // on Windows (LNK4229), leaving __ubsan_handle_* unresolved when
        // the static archive is consumed by an external linker.
        if (self.options.target.result.abi == .msvc) {
            try flag_builder.appendSlice(self.builder.allocator, &.{
                "-fno-sanitize=undefined",
                "-fno-sanitize-trap=undefined",
            });
        }
        if (self.options.target.result.os.tag != .windows) {
            try flag_builder.appendSlice(self.builder.allocator, &.{
                "-DHAVE_UNISTD_H",
                "-DHAVE_SYS_MMAN_H",
                "-DHAVE_PTHREAD=1",
            });
        }

        // Freetype flags/non-system include paths
        if (self.options.freetype != null) {
            try flag_builder.appendSlice(self.builder.allocator, &.{
                "-DHAVE_FREETYPE=1",

                // Let's just assume a new freetype
                "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
                "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
                "-DHAVE_FT_DONE_MM_VAR=1",
                "-DHAVE_FT_GET_TRANSFORM=1",
            });
        }

        // Coretext
        if (self.options.coretext) {
            try flag_builder.appendSlice(self.builder.allocator, &.{"-DHAVE_CORETEXT=1"});
        }

        return flag_builder.items;
    }

    fn addImportToModule(
        self: *const HarfBuzzC,
        module: *std.Build.Module,
    ) !void {
        try translate_c.addImportToModule(self.builder, "hb_c", module, .{
            .source = .{ .includes = .{ .files = try self.includeFiles() } },
            .target = self.options.target,
            .optimize = self.options.optimize,
            .link_system_libs = try self.systemLibs(),
            .include_paths = try self.includePaths(),
            .link_frameworks = self.frameworks(),
            .extra_args = try self.flags(),
        });
    }

    fn buildLib(self: *const HarfBuzzC) !*std.Build.Step.Compile {
        const target = self.options.target;
        const optimize = self.options.optimize;

        const lib = self.builder.addLibrary(.{
            .name = "harfbuzz",
            .root_module = self.builder.createModule(.{
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

        // Freetype
        if (self.options.freetype) |ft| {
            switch (ft.link_mode) {
                .dynamic => |opts| lib.root_module.linkSystemLibrary("freetype2", opts),
                .static => {
                    lib.root_module.linkLibrary(ft.dependency.artifact("freetype"));
                },
            }
        }

        // CoreText stuff
        for (self.frameworks()) |framework| lib.root_module.linkFramework(framework, .{});
        if (target.result.os.tag.isDarwin()) {
            try apple_sdk.addPaths(self.builder, lib);
        }

        if (self.builder.lazyDependency("harfbuzz", .{})) |upstream| {
            lib.root_module.addIncludePath(upstream.path("src"));
            lib.root_module.addCSourceFile(.{
                .file = upstream.path("src/harfbuzz.cc"),
                .flags = try self.flags(),
            });
            lib.installHeadersDirectory(
                upstream.path("src"),
                "",
                .{ .include_extensions = &.{".h"} },
            );
        }

        self.builder.installArtifact(lib);

        return lib;
    }
};
