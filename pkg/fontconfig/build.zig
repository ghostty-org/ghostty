const std = @import("std");
const build_zon = @import("build.zig.zon");
const NativeTargetInfo = std.zig.system.NativeTargetInfo;

// NOTE: This build is becoming more and more complex; we need to continually
// extract the correct options from fontconfig build process (although this
// part has been reasonably manageable for now); more concerning is the fact
// that we also need to now extract more generated files as fontconfig is
// leaning on generation more during their own Autoconf/Meson toolchain.
// Additionally, the Autoconf process (which incidentally is what Nix uses as
// well) has been deprecated since 2.18.3 (based on tracking the contents of
// the INSTALL file), which means we will need to lean on Meson more and more
// for this data.
//
// For now, autoconf still seems to work and can get us the files we need.
//
// If this build fails for any reason during update, you will need to inspect
// the build logs and extract any possible missing headers. These can be
// fetched through the following:
//
// * Set yourself up a Nix flake or build environment otherwise with the
//   following deps (note: these were extracted from the Nix package itself):
//
//     autoconf
//     automake
//     expat
//     freetype
//     gettext
//     gperf
//     libtool
//     libxslt
//     pkg-config
//     python3
//
// * Fetch the fontconfig source and extract it in this environment.
//
// * In the source root, run "./autogen.sh" followed by "make". (Don't run
//   "make install").
//
// * You should now have a reasonable set of files that you can use to hunt for
//   any missing auto-generated headers and plumb through errors otherwise.
//
// * Make sure when you copy includes and what not into the "override" tree,
//   that you preserve directory structure. This will help us keep track of what
//   we need and where it specifically came from.

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
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const tests_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);

    if (b.systemIntegrationOption("fontconfig", .{})) {
        module.linkSystemLibrary("fontconfig", dynamic_link_opts);
        test_exe.root_module.linkSystemLibrary("fontconfig", dynamic_link_opts);
    } else {
        const lib = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,

            .libxml2_enabled = libxml2_enabled,
            .libxml2_iconv_enabled = libxml2_iconv_enabled,
            .freetype_enabled = freetype_enabled,

            .dynamic_link_opts = dynamic_link_opts,
        });

        test_exe.root_module.linkLibrary(lib);
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const libxml2_enabled = options.libxml2_enabled;
    const libxml2_iconv_enabled = options.libxml2_iconv_enabled;
    const freetype_enabled = options.freetype_enabled;

    const lib = b.addLibrary(.{
        .name = "fontconfig",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });

    const dynamic_link_opts = options.dynamic_link_opts;

    if (target.result.os.tag != .windows) {
        lib.root_module.linkSystemLibrary("pthread", dynamic_link_opts);
    }

    // NOTE: The following directories are present in override but don't need
    // to be added here:
    //
    //   override/fc-case
    //
    inline for (.{
        "override",
        "override/fc-const",
        "override/fc-genericfamily",
        "override/fc-lang",
        "override/src",
    }) |override_dir| {
        lib.root_module.addIncludePath(b.path(override_dir));
        module.addIncludePath(b.path(override_dir));
    }

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);

    const version = try std.SemanticVersion.parse(build_zon.version);
    try flags.appendSlice(b.allocator, &.{
        b.fmt("-DFC_VERSION_MAJOR={d}", .{version.major}),
        b.fmt("-DFC_VERSION_MINOR={d}", .{version.minor}),
        b.fmt("-DFC_VERSION_MICRO={d}", .{version.patch}),
    });

    try flags.appendSlice(b.allocator, &.{
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
        "-DHAVE_VSNPRINTF",

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
        32 => try flags.appendSlice(b.allocator, &.{
            "-DSIZEOF_VOID_P=4",
            "-DALIGNOF_VOID_P=4",
        }),

        64 => try flags.appendSlice(b.allocator, &.{
            "-DSIZEOF_VOID_P=8",
            "-DALIGNOF_VOID_P=8",
        }),

        else => @panic("unsupported arch"),
    }
    if (target.result.os.tag == .windows) {
        try flags.appendSlice(b.allocator, &.{
            "-DFC_CACHEDIR=\"LOCAL_APPDATA_FONTCONFIG_CACHE\"",
            "-DFC_TEMPLATEDIR=\"c:/share/fontconfig/conf.avail\"",
            "-DCONFIGDIR=\"c:/etc/fonts/conf.d\"",
            "-DFC_DEFAULT_FONTS=\"\\t<dir>WINDOWSFONTDIR</dir>\\n\\t<dir>WINDOWSUSERFONTDIR</dir>\\n\"",
        });
    } else {
        try flags.appendSlice(b.allocator, &.{
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
            "-DHAVE_USELOCALE",
            "-DHAVE_SYS_MOUNT_H",
            "-DHAVE_SYS_STATVFS_H",

            "-DFC_CACHEDIR=\"/var/cache/fontconfig\"",
            "-DFC_DEFAULT_FONTS=\"<dir>/usr/share/fonts</dir><dir>/usr/local/share/fonts</dir>\"",
        });

        if (target.result.os.tag == .freebsd) {
            try flags.appendSlice(b.allocator, &.{
                "-DFC_TEMPLATEDIR=\"/usr/local/etc/fonts/conf.avail\"",
                "-DFONTCONFIG_PATH=\"/usr/local/etc/fonts\"",
                "-DCONFIGDIR=\"/usr/local/etc/fonts/conf.d\"",
            });
        } else {
            try flags.appendSlice(b.allocator, &.{
                "-DFC_TEMPLATEDIR=\"/usr/share/fontconfig/conf.avail\"",
                "-DFONTCONFIG_PATH=\"/etc/fonts\"",
                "-DCONFIGDIR=\"/usr/local/fontconfig/conf.d\"",
            });
        }

        if (target.result.os.tag == .linux) {
            try flags.appendSlice(b.allocator, &.{
                "-DHAVE_SYS_STATFS_H",
                "-DHAVE_SYS_VFS_H",
            });
        }
    }

    // Freetype2
    _ = b.systemIntegrationOption("freetype", .{}); // So it shows up in help
    if (freetype_enabled) {
        // Value-tested (#if/#elif) by upstream so it must be =1.
        try flags.append(b.allocator, "-DENABLE_FREETYPE=1");
        if (b.systemIntegrationOption("freetype", .{})) {
            lib.root_module.linkSystemLibrary("freetype2", dynamic_link_opts);
        } else {
            if (b.lazyDependency(
                "freetype",
                .{ .target = target, .optimize = optimize },
            )) |freetype_dep| {
                lib.root_module.linkLibrary(freetype_dep.artifact("freetype"));
            }
        }
    }

    // Libxml2
    _ = b.systemIntegrationOption("libxml2", .{}); // So it shows up in help
    if (libxml2_enabled) {
        try flags.appendSlice(b.allocator, &.{
            "-DENABLE_LIBXML2",
            "-DLIBXML_STATIC",
            "-DLIBXML_PUSH_ENABLED",
        });
        if (target.result.os.tag == .windows) {
            // NOTE: this should be defined on all targets
            try flags.appendSlice(b.allocator, &.{
                "-Werror=implicit-function-declaration",
            });
        }

        if (b.systemIntegrationOption("libxml2", .{})) {
            lib.root_module.linkSystemLibrary("libxml-2.0", dynamic_link_opts);
        } else {
            if (b.lazyDependency("libxml2", .{
                .target = target,
                .optimize = optimize,
                .iconv = libxml2_iconv_enabled,
            })) |libxml2_dep| {
                lib.root_module.linkLibrary(libxml2_dep.artifact("xml2"));
            }
        }
    }

    if (b.lazyDependency("fontconfig", .{})) |upstream| {
        lib.root_module.addIncludePath(upstream.path(""));
        module.addIncludePath(upstream.path(""));
        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = srcs,
            .flags = flags.items,
        });

        lib.installHeadersDirectory(
            upstream.path("fontconfig"),
            "fontconfig",
            .{ .include_extensions = &.{".h"} },
        );

        // Upstream only ships fontconfig.h.in; we generate fontconfig.h into
        // our override directory.
        //
        // TODO: I'm not too sure if this is fully needed - testing the build
        // with both system integration on and off seems to be not break with
        // this missing (and for that matter, all of the header install stuff
        // we do, funny enough).
        lib.installHeader(
            b.path("override/fontconfig/fontconfig.h"),
            "fontconfig/fontconfig.h",
        );
    }

    b.installArtifact(lib);

    return lib;
}

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
    "src/fcgenericalias.c",
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
