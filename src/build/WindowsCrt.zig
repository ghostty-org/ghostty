//! Helpers for linking the MSVC C runtime into Windows DLLs.
const std = @import("std");

/// Link the full CRT library chain required to build a DLL with the MSVC
/// ABI. Linking libc provides msvcrt.lib, but that references symbols in
/// vcruntime.lib and ucrt.lib. Zig's library search paths include the MSVC
/// lib dir and the Windows SDK 'um' dir, but not the SDK 'ucrt' dir where
/// ucrt.lib lives.
///
/// If the SDK can't be found, `lib` is made to fail when it is built
/// rather than when the build graph is configured, since many builds
/// that target MSVC never build the DLL and don't need the SDK.
pub fn link(b: *std.Build, lib: *std.Build.Step.Compile) void {
    const target = lib.rootModuleTarget();
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    // The CRT initialization code in msvcrt.lib calls __vcrt_initialize
    // and __acrt_initialize; ensure the vcruntime and ucrt libraries are
    // linked explicitly (they are not always discovered automatically).
    lib.root_module.linkSystemLibrary("libvcruntime", dynamic_link_opts);
    lib.root_module.linkSystemLibrary("libucrt", dynamic_link_opts);

    // ucrt.lib is in the Windows SDK 'ucrt' dir. Detect the SDK
    // installation and add the UCRT library path.
    const arch = target.cpu.arch;
    const arch_str: []const u8 = switch (arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => return failBuild(b, lib, b.fmt(
            "unsupported architecture for the Windows UCRT: {t}",
            .{arch},
        )),
    };
    const sdk = std.zig.WindowsSdk.find(
        b.allocator,
        b.graph.io,
        arch,
        &b.graph.environ_map,
    ) catch |err| return failBuild(b, lib, b.fmt(
        "unable to find the Windows SDK: {t}",
        .{err},
    ));
    const w10 = sdk.windows10sdk orelse return failBuild(
        b,
        lib,
        "the Windows 10/11 SDK (which provides ucrt.lib) was not found",
    );
    const ucrt_lib_path = b.fmt(
        "{s}\\Lib\\{s}\\ucrt\\{s}",
        .{ w10.path, w10.version, arch_str },
    );
    lib.root_module.addLibraryPath(.{ .cwd_relative = ucrt_lib_path });
}

fn failBuild(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    msg: []const u8,
) void {
    lib.step.dependOn(&b.addFail(msg).step);
}
