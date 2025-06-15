const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "breakpad",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibCpp();
    lib.addIncludePath(b.path("vendor"));
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{});

    if (b.lazyDependency("breakpad", .{})) |upstream| {
        lib.addIncludePath(upstream.path("src"));
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = common,
            .flags = flags.items,
        });

        if (target.result.os.tag.isDarwin()) {
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = common_apple,
                .flags = flags.items,
            });
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = client_apple,
                .flags = flags.items,
            });

            switch (target.result.os.tag) {
                .macos => {
                    lib.addCSourceFiles(.{
                        .root = upstream.path(""),
                        .files = common_mac,
                        .flags = flags.items,
                    });
                    lib.addCSourceFiles(.{
                        .root = upstream.path(""),
                        .files = client_mac,
                        .flags = flags.items,
                    });
                },

                .ios => lib.addCSourceFiles(.{
                    .root = upstream.path(""),
                    .files = client_ios,
                    .flags = flags.items,
                }),

                else => {},
            }
        }

        if (target.result.os.tag == .linux) {
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = common_linux,
                .flags = flags.items,
            });
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = client_linux,
                .flags = flags.items,
            });
        }

        lib.installHeadersDirectory(
            upstream.path("src"),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);
}

const common: []const []const u8 = &.{
    "src/common/convert_UTF.cc",
    "src/common/md5.cc",
    "src/common/string_conversion.cc",
};

const common_linux: []const []const u8 = &.{
    "src/common/linux/elf_core_dump.cc",
    "src/common/linux/elfutils.cc",
    "src/common/linux/file_id.cc",
    "src/common/linux/guid_creator.cc",
    "src/common/linux/linux_libc_support.cc",
    "src/common/linux/memory_mapped_file.cc",
    "src/common/linux/safe_readlink.cc",
    "src/common/linux/scoped_pipe.cc",
    "src/common/linux/scoped_tmpfile.cc",
    "src/common/linux/breakpad_getcontext.S",
};

const common_apple: []const []const u8 = &.{
    "src/common/mac/arch_utilities.cc",
    "src/common/mac/file_id.cc",
    "src/common/mac/macho_id.cc",
    "src/common/mac/macho_utilities.cc",
    "src/common/mac/macho_walker.cc",
    "src/common/mac/string_utilities.cc",
};

const common_mac: []const []const u8 = &.{
    "src/common/mac/MachIPC.mm",
    "src/common/mac/bootstrap_compat.cc",
};

const client_linux: []const []const u8 = &.{
    "src/client/minidump_file_writer.cc",
    "src/client/linux/crash_generation/crash_generation_client.cc",
    "src/client/linux/crash_generation/crash_generation_server.cc",
    "src/client/linux/dump_writer_common/thread_info.cc",
    "src/client/linux/dump_writer_common/ucontext_reader.cc",
    "src/client/linux/handler/exception_handler.cc",
    "src/client/linux/handler/minidump_descriptor.cc",
    "src/client/linux/log/log.cc",
    "src/client/linux/microdump_writer/microdump_writer.cc",
    "src/client/linux/minidump_writer/linux_core_dumper.cc",
    "src/client/linux/minidump_writer/linux_dumper.cc",
    "src/client/linux/minidump_writer/linux_ptrace_dumper.cc",
    "src/client/linux/minidump_writer/minidump_writer.cc",
    "src/client/linux/minidump_writer/pe_file.cc",
};

const client_apple: []const []const u8 = &.{
    "src/client/minidump_file_writer.cc",
    "src/client/mac/handler/breakpad_nlist_64.cc",
    "src/client/mac/handler/dynamic_images.cc",
    "src/client/mac/handler/minidump_generator.cc",
};

const client_mac: []const []const u8 = &.{
    "src/client/mac/handler/exception_handler.cc",
    "src/client/mac/crash_generation/crash_generation_client.cc",
};

const client_ios: []const []const u8 = &.{
    "src/client/ios/exception_handler_no_mach.cc",
    "src/client/ios/handler/ios_exception_minidump_generator.mm",
    "src/client/mac/crash_generation/ConfigFile.mm",
    "src/client/mac/handler/protected_memory_allocator.cc",
};
