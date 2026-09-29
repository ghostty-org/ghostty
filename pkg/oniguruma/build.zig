const std = @import("std");
const translate_c = @import("translate_c");
const NativeTargetInfo = std.zig.system.NativeTargetInfo;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("oniguruma", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    var test_exe: ?*std.Build.Step.Compile = null;
    if (target.query.isNative()) {
        test_exe = b.addTest(.{
            .name = "test",
            .root_module = module,
        });
        const tests_run = b.addRunArtifact(test_exe.?);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);

        // Uncomment this if we're debugging tests
        b.installArtifact(test_exe.?);
    }

    const lib: union(enum) {
        system,
        static: *std.Build.Step.Compile,
    } = if (b.systemIntegrationOption("oniguruma", .{}))
        .system
    else
        .{ .static = try buildLib(b, .{
            .target = target,
            .optimize = optimize,
        }) };

    try translate_c.addImportToModule(b, "oniguruma_c", module, .{
        .source = .{ .includes = .{
            .files = &.{.{ .path = "oniguruma.h" }},
        } },
        .target = target,
        .optimize = optimize,
        .link_system_libs = if (lib == .system) &.{"oniguruma"} else &.{},
        .link_libs = if (lib == .static) &.{lib.static} else &.{},
    });
}

fn buildLib(b: *std.Build, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const lib = b.addLibrary(.{
        .name = "oniguruma",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    const t = target.result;
    const is_windows = t.os.tag == .windows;

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    if (b.lazyDependency("oniguruma", .{})) |upstream| {
        lib.root_module.addIncludePath(upstream.path("src"));
        lib.root_module.addConfigHeader(b.addConfigHeader(.{
            .style = .{ .cmake = upstream.path("src/config.h.cmake.in") },
        }, .{
            .PACKAGE = "oniguruma",
            .PACKAGE_VERSION = "6.9.9",
            .VERSION = "6.9.9",
            .HAVE_ALLOCA = true,
            .HAVE_ALLOCA_H = !is_windows,
            .USE_CRNL_AS_LINE_TERMINATOR = is_windows,
            .HAVE_STDINT_H = true,
            .HAVE_SYS_TIMES_H = !is_windows,
            .HAVE_SYS_TIME_H = !is_windows,
            .HAVE_SYS_TYPES_H = true,
            .HAVE_UNISTD_H = !is_windows,
            .HAVE_INTTYPES_H = true,
            .SIZEOF_INT = t.cTypeByteSize(.int),
            .SIZEOF_LONG = t.cTypeByteSize(.long),
            .SIZEOF_LONG_LONG = t.cTypeByteSize(.longlong),
            .SIZEOF_VOIDP = t.ptrBitWidth() / t.cTypeBitSize(.char),
        }));

        var flags: std.ArrayList([]const u8) = .empty;
        defer flags.deinit(b.allocator);
        if (target.result.abi == .msvc) {
            try flags.appendSlice(b.allocator, &.{
                "-fno-sanitize=undefined",
                "-fno-sanitize-trap=undefined",
            });
        }
        lib.root_module.addCSourceFiles(.{
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
