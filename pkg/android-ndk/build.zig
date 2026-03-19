const std = @import("std");
const builtin = @import("builtin");

pub fn build(_: *std.Build) !void {}

// Configure the step to point to the Android NDK for libc and include
// paths. This requires the Android NDK installed in the system and
// setting the appropriate environment variables or installing the NDK
// in the default location.
//
// The environment variables can be set as follows:
// - `ANDROID_NDK_HOME`: Directly points to the NDK path, including the version.
// - `ANDROID_HOME` or `ANDROID_SDK_ROOT`: Points to the Android SDK path;
//   latest available NDK will be automatically selected.
//
// NB: This is a workaround until zig natively supports bionic
// cross-compilation (ziglang/zig#23906).
pub fn addPaths(b: *std.Build, step: *std.Build.Step.Compile) !void {
    const Cache = struct {
        const Key = struct {
            arch: std.Target.Cpu.Arch,
            abi: std.Target.Abi,
            api_level: u32,
        };

        var map: std.AutoHashMapUnmanaged(Key, ?struct {
            libc: std.Build.LazyPath,
            cpp_include: std.Build.LazyPath,
            lib: std.Build.LazyPath,
        }) = .empty;
    };

    const target = step.rootModuleTarget();
    const gop = try Cache.map.getOrPut(b.allocator, .{
        .arch = target.cpu.arch,
        .abi = target.abi,
        .api_level = target.os.version_range.linux.android,
    });

    if (!gop.found_existing) {
        const ndk_path = findNDKPath(b) orelse return error.AndroidNDKNotFound;

        const ndk_triple = ndkTriple(target) orelse {
            gop.value_ptr.* = null;
            return error.AndroidNDKUnsupportedTarget;
        };

        const host = hostTag() orelse {
            gop.value_ptr.* = null;
            return error.AndroidNDKUnsupportedHost;
        };

        const sysroot = b.pathJoin(&.{
            ndk_path,
            "toolchains",
            "llvm",
            "prebuilt",
            host,
            "sysroot",
        });
        const include_dir = b.pathJoin(&.{
            sysroot,
            "usr",
            "include",
        });
        const sys_include_dir = b.pathJoin(&.{
            sysroot,
            "usr",
            "include",
            ndk_triple,
        });
        const c_runtime_dir = b.pathJoin(&.{
            sysroot,
            "usr",
            "lib",
            ndk_triple,
            b.fmt("{d}", .{target.os.version_range.linux.android}),
        });
        const lib = b.pathJoin(&.{
            sysroot,
            "usr",
            "lib",
            ndk_triple,
        });
        const cpp_include = b.pathJoin(&.{
            sysroot,
            "usr",
            "include",
            "c++",
            "v1",
        });

        const libc_txt = b.fmt(
            \\include_dir={s}
            \\sys_include_dir={s}
            \\crt_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\gcc_dir=
        , .{ include_dir, sys_include_dir, c_runtime_dir });

        const wf = b.addWriteFiles();
        const libc_path = wf.add("libc.txt", libc_txt);

        gop.value_ptr.* = .{
            .libc = libc_path,
            .cpp_include = .{ .cwd_relative = cpp_include },
            .lib = .{ .cwd_relative = lib },
        };
    }

    const value = gop.value_ptr.* orelse return error.AndroidNDKNotFound;

    step.setLibCFile(value.libc);
    step.root_module.addSystemIncludePath(value.cpp_include);
    step.root_module.addLibraryPath(value.lib);
}

fn findNDKPath(b: *std.Build) ?[]const u8 {
    // Check if user has set the environment variable for the NDK path.
    if (std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME") catch null) |value| {
        if (value.len == 0) return null;
        var dir = std.fs.openDirAbsolute(value, .{}) catch return null;
        defer dir.close();
        return value;
    }

    // Check the common environment variables for the Android SDK path and look for the NDK inside it.
    inline for (.{ "ANDROID_HOME", "ANDROID_SDK_ROOT" }) |env| {
        if (std.process.getEnvVarOwned(b.allocator, env) catch null) |sdk| {
            if (sdk.len > 0) {
                if (findLatestNDK(b, sdk)) |ndk| return ndk;
            }
        }
    }

    // As a fallback, we assume the most common/default SDK path based on the OS.
    const home = std.process.getEnvVarOwned(
        b.allocator,
        if (builtin.os.tag == .windows) "LOCALAPPDATA" else "HOME",
    ) catch return null;

    const default_sdk_path = b.pathJoin(
        &.{
            home,
            switch (builtin.os.tag) {
                .linux => "Android/sdk",
                .macos => "Library/Android/Sdk",
                .windows => "Android/Sdk",
                else => return null,
            },
        },
    );

    return findLatestNDK(b, default_sdk_path);
}

fn findLatestNDK(b: *std.Build, sdk_path: []const u8) ?[]const u8 {
    const ndk_dir = b.pathJoin(&.{ sdk_path, "ndk" });
    var dir = std.fs.openDirAbsolute(ndk_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var latest_: ?struct {
        name: []const u8,
        version: std.SemanticVersion,
    } = null;
    var iterator = dir.iterate();

    while (iterator.next() catch null) |file| {
        if (file.kind != .directory) continue;
        const version = std.SemanticVersion.parse(file.name) catch continue;
        if (latest_) |latest| {
            if (version.order(latest.version) != .gt) continue;
        }
        latest_ = .{
            .name = file.name,
            .version = version,
        };
    }

    const latest = latest_ orelse return null;

    return b.pathJoin(&.{ sdk_path, "ndk", latest.name });
}

fn hostTag() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        // All darwin hosts use the same prebuilt binaries
        // (https://developer.android.com/ndk/guides/other_build_systems).
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => null,
    };
}

// We must map the target architecture to the corresponding NDK triple following the NDK
// documentation: https://android.googlesource.com/platform/ndk/+/master/docs/BuildSystemMaintainers.md#architectures
fn ndkTriple(target: std.Target) ?[]const u8 {
    return switch (target.cpu.arch) {
        .arm => "arm-linux-androideabi",
        .aarch64 => "aarch64-linux-android",
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        else => null,
    };
}
