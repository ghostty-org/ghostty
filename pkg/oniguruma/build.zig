const std = @import("std");
const NativeTargetInfo = std.zig.system.NativeTargetInfo;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("oniguruma", .{
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

    var test_exe: ?*std.Build.Step.Compile = null;
    if (target.query.isNative()) {
        test_exe = b.addTest(.{
            .name = "test",
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        });
        const tests_run = b.addRunArtifact(test_exe.?);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);

        // Uncomment this if we're debugging tests
        b.installArtifact(test_exe.?);
    }

    if (b.systemIntegrationOption("oniguruma", .{})) {
        module.linkSystemLibrary("oniguruma", dynamic_link_opts);

        if (test_exe) |exe| {
            exe.linkSystemLibrary2("oniguruma", dynamic_link_opts);
        }
    } else {
        const lib = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,
        });

        if (test_exe) |exe| {
            exe.linkLibrary(lib);
        }
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const lib = b.addStaticLibrary(.{
        .name = "oniguruma",
        .target = target,
        .optimize = optimize,
    });
    const t = target.result;
    lib.linkLibC();

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    if (b.lazyDependency("oniguruma", .{})) |upstream| {
        lib.addIncludePath(upstream.path("src"));
        module.addIncludePath(upstream.path("src"));

        lib.addConfigHeader(b.addConfigHeader(.{
            .style = .{ .cmake = upstream.path("src/config.h.cmake.in") },
        }, .{
            .PACKAGE = "oniguruma",
            .PACKAGE_VERSION = "6.9.9",
            .VERSION = "6.9.9",
            .HAVE_ALLOCA = true,
            .HAVE_ALLOCA_H = true,
            .USE_CRNL_AS_LINE_TERMINATOR = false,
            .HAVE_STDINT_H = true,
            .HAVE_SYS_TIMES_H = true,
            .HAVE_SYS_TIME_H = true,
            .HAVE_SYS_TYPES_H = true,
            .HAVE_UNISTD_H = true,
            .HAVE_INTTYPES_H = true,
            .SIZEOF_INT = t.cTypeByteSize(.int),
            .SIZEOF_LONG = t.cTypeByteSize(.long),
            .SIZEOF_LONG_LONG = t.cTypeByteSize(.longlong),
            .SIZEOF_VOIDP = t.ptrBitWidth() / t.cTypeBitSize(.char),
        }));

        var flags = std.ArrayList([]const u8).init(b.allocator);
        defer flags.deinit();
        try flags.appendSlice(&.{});
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .flags = flags.items,
            .files = &.{
                "src/regerror.c",
                "src/regparse.c",
                "src/regext.c",
                "src/regcomp.c",
                "src/regexec.c",
                "src/reggnu.c",
                "src/regenc.c",
                "src/regsyntax.c",
                "src/regtrav.c",
                "src/regversion.c",
                "src/st.c",
                "src/onig_init.c",
                "src/unicode.c",
                "src/ascii.c",
                "src/utf8.c",
                "src/utf16_be.c",
                "src/utf16_le.c",
                "src/utf32_be.c",
                "src/utf32_le.c",
                "src/euc_jp.c",
                "src/sjis.c",
                "src/iso8859_1.c",
                "src/iso8859_2.c",
                "src/iso8859_3.c",
                "src/iso8859_4.c",
                "src/iso8859_5.c",
                "src/iso8859_6.c",
                "src/iso8859_7.c",
                "src/iso8859_8.c",
                "src/iso8859_9.c",
                "src/iso8859_10.c",
                "src/iso8859_11.c",
                "src/iso8859_13.c",
                "src/iso8859_14.c",
                "src/iso8859_15.c",
                "src/iso8859_16.c",
                "src/euc_tw.c",
                "src/euc_kr.c",
                "src/big5.c",
                "src/gb18030.c",
                "src/koi8_r.c",
                "src/cp1251.c",
                "src/euc_jp_prop.c",
                "src/sjis_prop.c",
                "src/unicode_unfold_key.c",
                "src/unicode_fold1_key.c",
                "src/unicode_fold2_key.c",
                "src/unicode_fold3_key.c",
            },
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
