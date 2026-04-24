const std = @import("std");

const no_libc_flags = [_][]const u8{
    "-DSIMDUTF_NO_LIBC=1",
    "-DSIMDUTF_LIBC_MEMCPY=simdutf_memcpy",
    "-DSIMDUTF_LIBC_MEMMOVE=simdutf_memmove",
    "-DSIMDUTF_LIBC_MEMSET=simdutf_memset",
    "-DSIMDUTF_LIBC_MEMCMP=simdutf_memcmp",
    "-DSIMDUTF_LIBC_STRLEN=simdutf_strlen",
    "-DSIMDUTF_LIBC_GETENV=simdutf_getenv",
};

pub fn noLibcFlags() []const []const u8 {
    return &no_libc_flags;
}

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const no_libcxx = b.option(bool, "no_libcxx", "Set SIMDUTF_NO_LIBCXX to avoid libc++ dependency") orelse false;
    const no_libc = b.option(bool, "no_libc", "Set SIMDUTF_NO_LIBC and provide Zig stdlib replacements") orelse false;

    const lib = b.addLibrary(.{
        .name = "simdutf",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.addIncludePath(b.path("vendor"));
    if (!no_libc) lib.linkLibC();
    libcpp: {
        if (target.result.abi == .msvc) {
            // On MSVC, we must not use linkLibCpp because Zig unconditionally
            // passes -nostdinc++ and then adds its bundled libc++/libc++abi
            // include paths, which conflict with MSVC's own C++ runtime headers.
            // The MSVC SDK include directories (added via linkLibC) contain
            // both C and C++ headers, so linkLibCpp is not needed.
            break :libcpp;
        }

        // We link libcpp even with no_libcxx because simdutf requires
        // libc++ headers at build time. But it doesn't require libc++
        // at runtime. For Ghostty itself, we have CI tests to verify this.
        lib.linkLibCpp();
    }

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    if (target.result.abi.isAndroid()) {
        const android_ndk = @import("android_ndk");
        try android_ndk.addPaths(b, lib);
    }

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
    // (See root Ghostty build.zig on why we do this)
    try flags.append(b.allocator, "-DSIMDUTF_IMPLEMENTATION_ICELAKE=0");

    // Fixes linker issues for release builds missing ubsanitizer symbols
    try flags.appendSlice(b.allocator, &.{
        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    if (no_libcxx) {
        try flags.append(b.allocator, "-DSIMDUTF_NO_LIBCXX");
        if (target.result.abi != .msvc) {
            // Clang/GCC-only flags; MSVC doesn't accept these.
            try flags.append(b.allocator, "-fno-exceptions");
            try flags.append(b.allocator, "-fno-rtti");
        }

        lib.root_module.addCMacro("SIMDUTF_NO_LIBCXX", "1");
    }

    if (no_libc) {
        try flags.appendSlice(b.allocator, noLibcFlags());

        lib.root_module.addCMacro("SIMDUTF_NO_LIBC", "1");

        const no_libc_obj = b.addObject(.{
            .name = "simdutf_no_libc",
            .root_module = b.createModule(.{
                .root_source_file = b.path("no_libc.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .pic = true,
            }),
        });
        lib.addObject(no_libc_obj);
    }

    if (target.result.abi == .msvc) {
        // On MSVC we skip linkLibCpp (see above), so the C++ standard is
        // not set implicitly. simdutf requires C++17, so set it explicitly.
        try flags.append(b.allocator, "-std=c++17");
    }

    if (target.result.os.tag == .freebsd or target.result.abi == .musl) {
        try flags.append(b.allocator, "-fPIC");
    }

    lib.addCSourceFiles(.{
        .flags = flags.items,
        .files = &.{
            "vendor/simdutf.cpp",
        },
    });
    lib.installHeadersDirectory(
        b.path("vendor"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(lib);

    // {
    //     const test_exe = b.addTest(.{
    //         .name = "test",
    //         .root_source_file = .{ .path = "main.zig" },
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     test_exe.linkLibrary(lib);
    //
    //     var it = module.import_table.iterator();
    //     while (it.next()) |entry| test_exe.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
    //     const tests_run = b.addRunArtifact(test_exe);
    //     const test_step = b.step("test", "Run tests");
    //     test_step.dependOn(&tests_run.step);
    // }
}
