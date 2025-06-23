const std = @import("std");
const NativeTargetInfo = std.zig.system.NativeTargetInfo;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxml2_enabled = b.option(bool, "enable-libxml2", "Build libxml2") orelse true;
    const libxml2_iconv_enabled = b.option(
        bool,
        "enable-libxml2-iconv",
        "Build libxml2 with iconv",
    ) orelse (target.result.os.tag != .windows);
    const freetype_enabled = b.option(bool, "enable-freetype", "Build freetype") orelse true;

    const module = b.addModule("fontconfig", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    const test_exe = b.addTest(.{
        .name = "test",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);

    if (b.systemIntegrationOption("fontconfig", .{})) {
        module.linkSystemLibrary("fontconfig", dynamic_link_opts);
        test_exe.linkSystemLibrary2("fontconfig", dynamic_link_opts);
    } else {
        const lib = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,

            .libxml2_enabled = libxml2_enabled,
            .libxml2_iconv_enabled = libxml2_iconv_enabled,
            .freetype_enabled = freetype_enabled,

            .dynamic_link_opts = dynamic_link_opts,
        });

        test_exe.linkLibrary(lib);
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const libxml2_enabled = options.libxml2_enabled;
    const libxml2_iconv_enabled = options.libxml2_iconv_enabled;
    const freetype_enabled = options.freetype_enabled;

    const lib = b.addStaticLibrary(.{
        .name = "fontconfig",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    if (target.result.os.tag != .windows) {
        lib.linkSystemLibrary("pthread");
    }

    lib.addIncludePath(b.path("override/include"));
    module.addIncludePath(b.path("override/include"));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-DHAVE_DIRENT_H",
        "-DHAVE_FCNTL_H",
        "-DHAVE_STDLIB_H",
        "-DHAVE_STRING_H",
        "-DHAVE_UNISTD_H",
        "-DHAVE_SYS_PARAM_H",

        "-DHAVE_MKSTEMP",
        //"-DHAVE_GETPROGNAME",
        //"-DHAVE_GETEXECNAME",
        "-DHAVE_RAND",
        //"-DHAVE_RANDOM_R",
        "-DHAVE_VPRINTF",

        "-DHAVE_FT_GET_BDF_PROPERTY",
        "-DHAVE_FT_GET_PS_FONT_INFO",
        "-DHAVE_FT_HAS_PS_GLYPH_NAMES",
        "-DHAVE_FT_GET_X11_FONT_FORMAT",
        "-DHAVE_FT_DONE_MM_VAR",

        "-DHAVE_POSIX_FADVISE",

        //"-DHAVE_STRUCT_STATVFS_F_BASETYPE",
        // "-DHAVE_STRUCT_STATVFS_F_FSTYPENAME",
        // "-DHAVE_STRUCT_STATFS_F_FLAGS",
        // "-DHAVE_STRUCT_STATFS_F_FSTYPENAME",
        // "-DHAVE_STRUCT_DIRENT_D_TYPE",

        "-DFLEXIBLE_ARRAY_MEMBER",

        "-DHAVE_STDATOMIC_PRIMITIVES",

        "-DFC_GPERF_SIZE_T=size_t",

        // Default errors that fontconfig can't handle
        "-Wno-implicit-function-declaration",
        "-Wno-int-conversion",

        // https://gitlab.freedesktop.org/fontconfig/fontconfig/-/merge_requests/231
        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    switch (target.result.ptrBitWidth()) {
        32 => try flags.appendSlice(&.{
            "-DSIZEOF_VOID_P=4",
            "-DALIGNOF_VOID_P=4",
        }),

        64 => try flags.appendSlice(&.{
            "-DSIZEOF_VOID_P=8",
            "-DALIGNOF_VOID_P=8",
        }),

        else => @panic("unsupported arch"),
    }
    if (target.result.os.tag == .windows) {
        try flags.appendSlice(&.{
            "-DFC_CACHEDIR=\"LOCAL_APPDATA_FONTCONFIG_CACHE\"",
            "-DFC_TEMPLATEDIR=\"c:/share/fontconfig/conf.avail\"",
            "-DCONFIGDIR=\"c:/etc/fonts/conf.d\"",
            "-DFC_DEFAULT_FONTS=\"\\t<dir>WINDOWSFONTDIR</dir>\\n\\t<dir>WINDOWSUSERFONTDIR</dir>\\n\"",
        });
    } else {
        try flags.appendSlice(&.{
            "-DHAVE_FSTATFS",
            "-DHAVE_FSTATVFS",
            "-DHAVE_GETOPT",
            "-DHAVE_GETOPT_LONG",
            "-DHAVE_LINK",
            "-DHAVE_LRAND48",
            "-DHAVE_LSTAT",
            "-DHAVE_MKDTEMP",
            "-DHAVE_MKOSTEMP",
            "-DHAVE__MKTEMP_S",
            "-DHAVE_MMAP",
            "-DHAVE_PTHREAD",
            "-DHAVE_RANDOM",
            "-DHAVE_RAND_R",
            "-DHAVE_READLINK",
            "-DHAVE_SYS_MOUNT_H",
            "-DHAVE_SYS_STATVFS_H",

            "-DFC_CACHEDIR=\"/var/cache/fontconfig\"",
            "-DFC_DEFAULT_FONTS=\"<dir>/usr/share/fonts</dir><dir>/usr/local/share/fonts</dir>\"",
        });

        if (target.result.os.tag == .freebsd) {
            try flags.appendSlice(&.{
                "-DFC_TEMPLATEDIR=\"/usr/local/etc/fonts/conf.avail\"",
                "-DFONTCONFIG_PATH=\"/usr/local/etc/fonts\"",
                "-DCONFIGDIR=\"/usr/local/etc/fonts/conf.d\"",
            });
        } else {
            try flags.appendSlice(&.{
                "-DFC_TEMPLATEDIR=\"/usr/share/fontconfig/conf.avail\"",
                "-DFONTCONFIG_PATH=\"/etc/fonts\"",
                "-DCONFIGDIR=\"/usr/local/fontconfig/conf.d\"",
            });
        }

        if (target.result.os.tag == .linux) {
            try flags.appendSlice(&.{
                "-DHAVE_SYS_STATFS_H",
                "-DHAVE_SYS_VFS_H",
            });
        }
    }

    const dynamic_link_opts = options.dynamic_link_opts;

    // Freetype2
    _ = b.systemIntegrationOption("freetype", .{}); // So it shows up in help
    if (freetype_enabled) {
        if (b.systemIntegrationOption("freetype", .{})) {
            lib.linkSystemLibrary2("freetype2", dynamic_link_opts);
        } else {
            if (b.lazyDependency(
                "freetype",
                .{ .target = target, .optimize = optimize },
            )) |freetype_dep| {
                lib.linkLibrary(freetype_dep.artifact("freetype"));
            }
        }
    }

    // Libxml2
    _ = b.systemIntegrationOption("libxml2", .{}); // So it shows up in help
    if (libxml2_enabled) {
        try flags.appendSlice(&.{
            "-DENABLE_LIBXML2",
            "-DLIBXML_STATIC",
            "-DLIBXML_PUSH_ENABLED",
        });
        if (target.result.os.tag == .windows) {
            // NOTE: this should be defined on all targets
            try flags.appendSlice(&.{
                "-Werror=implicit-function-declaration",
            });
        }

        if (b.systemIntegrationOption("libxml2", .{})) {
            lib.linkSystemLibrary2("libxml-2.0", dynamic_link_opts);
        } else {
            if (b.lazyDependency("libxml2", .{
                .target = target,
                .optimize = optimize,
                .iconv = libxml2_iconv_enabled,
            })) |libxml2_dep| {
                lib.linkLibrary(libxml2_dep.artifact("xml2"));
            }
        }
    }

    if (b.lazyDependency("fontconfig", .{})) |upstream| {
        lib.addIncludePath(upstream.path(""));
        module.addIncludePath(upstream.path(""));
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = srcs,
            .flags = flags.items,
        });

        lib.installHeadersDirectory(
            upstream.path("fontconfig"),
            "fontconfig",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    return lib;
}

const headers = &.{
    "fontconfig/fontconfig.h",
    "fontconfig/fcprivate.h",
    "fontconfig/fcfreetype.h",
};

const srcs: []const []const u8 = &.{
    "src/fcatomic.c",
    "src/fccache.c",
    "src/fccfg.c",
    "src/fccharset.c",
    "src/fccompat.c",
    "src/fcdbg.c",
    "src/fcdefault.c",
    "src/fcdir.c",
    "src/fcformat.c",
    "src/fcfreetype.c",
    "src/fcfs.c",
    "src/fcptrlist.c",
    "src/fchash.c",
    "src/fcinit.c",
    "src/fclang.c",
    "src/fclist.c",
    "src/fcmatch.c",
    "src/fcmatrix.c",
    "src/fcname.c",
    "src/fcobjs.c",
    "src/fcpat.c",
    "src/fcrange.c",
    "src/fcserialize.c",
    "src/fcstat.c",
    "src/fcstr.c",
    "src/fcweight.c",
    "src/fcxml.c",
    "src/ftglue.c",
};
