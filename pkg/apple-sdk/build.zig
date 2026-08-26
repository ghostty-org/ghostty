const std = @import("std");
const builtin = @import("builtin");

/// Helpers for linking Mach-O artifacts with Apple's native toolchain.
pub const nativeLink = @import("native_link.zig");

// The cache. This always uses b.allocator and never frees memory
// (which is idiomatic for a Zig build exe). We cache the libc txt
// file we create because it is expensive to generate (subprocesses).
pub const Cache = struct {
    const Key = struct {
        arch: std.Target.Cpu.Arch,
        os: std.Target.Os.Tag,
        abi: std.Target.Abi,
    };

    pub const Value = union(enum) {
        native: struct {
            libc: std.Build.LazyPath,
            framework: []const u8,
            system_include: []const u8,
            library: []const u8,
        },
        cross: struct {
            libc: std.Build.LazyPath,
        },
    };

    var map: std.AutoHashMapUnmanaged(Key, ?Value) = .{};
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = target;
    _ = optimize;
}

/// Fetch or load the paths for the proper Apple SDK for libc and
/// frameworks. When running on a Darwin host, this uses the native
/// SDK installed on the system via `xcrun`. When cross-compiling from
/// a non-Darwin host, it falls back to Zig's bundled Darwin headers.
pub fn pathsForTarget(b: *std.Build, target: std.Target) !Cache.Value {
    const gop = try Cache.map.getOrPut(b.allocator, .{
        .arch = target.cpu.arch,
        .os = target.os.tag,
        .abi = target.abi,
    });

    if (!gop.found_existing) init: {
        if (comptime builtin.os.tag.isDarwin()) darwin: {
            // Detect our SDK using the "findNative" Zig stdlib function.
            // This is really important because it forces using `xcrun` to
            // find the SDK path.
            var libc = std.zig.LibCInstallation.findNative(
                b.allocator,
                b.graph.io,
                .{
                    .environ_map = &b.graph.environ_map,
                    .target = &target,
                    .verbose = false,
                },
            ) catch break :darwin;

            // Xcode 27's math.h requests infinity and NaN definitions from
            // Clang's float.h using the __need_infinity_nan protocol. Zig
            // 0.16's bundled Clang resource headers predate that protocol, so
            // compiling Zig's bundled libc++ against the new SDK fails.
            //
            // Put our compatibility include directory between Zig's resource
            // headers and the selected SDK headers. Its math.h forwards to the
            // SDK with #include_next, then supplies the definitions missing
            // from Zig's float.h. This can be removed once Zig's bundled Clang
            // headers implement __need_infinity_nan.
            libc.include_dir = b.dependency("apple_sdk", .{})
                .path("include")
                .getPath(b);

            // Render the file compatible with the `--libc` Zig flag.
            var stream: std.Io.Writer.Allocating = .init(b.allocator);
            defer stream.deinit();
            try libc.render(&stream.writer);

            // Create a temporary file to store the libc path because
            // `--libc` expects a file path.
            const wf = b.addWriteFiles();
            const path = wf.add("libc.txt", stream.written());

            // Determine our framework path. Zig has a bug where it doesn't
            // parse this from the libc txt file for `-framework` flags:
            // https://github.com/ziglang/zig/issues/24024
            const framework_path = framework: {
                const down1 = std.fs.path.dirname(libc.sys_include_dir.?).?;
                const down2 = std.fs.path.dirname(down1).?;
                break :framework try std.fs.path.join(b.allocator, &.{
                    down2,
                    "System",
                    "Library",
                    "Frameworks",
                });
            };

            const library_path = library: {
                const down1 = std.fs.path.dirname(libc.sys_include_dir.?).?;
                break :library try std.fs.path.join(b.allocator, &.{
                    down1,
                    "lib",
                });
            };

            gop.value_ptr.* = .{ .native = .{
                .libc = path,
                .framework = framework_path,
                .system_include = libc.sys_include_dir.?,
                .library = library_path,
            } };

            break :init;
        }

        // Cross-compiling to Darwin from a non-Darwin host.
        // Zig only bundles macOS headers, so for other Apple platforms
        // we leave the value as null to produce a descriptive error.
        if (target.os.tag != .macos) {
            gop.value_ptr.* = null;
            break :init;
        }

        // Fall back to Zig's bundled Darwin headers for libc resolution.
        const zig_lib_path = b.graph.zig_lib_directory.path.?;
        const include_dir = b.pathJoin(&.{
            zig_lib_path, "libc", "include", "any-darwin-any",
        });

        const wf = b.addWriteFiles();
        const path = wf.add("libc.txt", b.fmt(
            \\include_dir={s}
            \\sys_include_dir={s}
            \\crt_dir=
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\gcc_dir=
            \\
        , .{ include_dir, include_dir }));

        gop.value_ptr.* = .{ .cross = .{ .libc = path } };
    }

    return gop.value_ptr.* orelse return switch (target.os.tag) {
        // Return a more descriptive error. Before we just returned the
        // generic error but this was confusing a lot of community members.
        // It costs us nothing in the build script to return something better.
        .macos => error.XcodeMacOSSDKNotFound,
        .ios => error.XcodeiOSSDKNotFound,
        .tvos => error.XcodeTVOSSDKNotFound,
        .watchos => error.XcodeWatchOSSDKNotFound,
        else => error.XcodeAppleSDKNotFound,
    };
}

/// Setup the step to point to the proper Apple SDK for libc and
/// frameworks. When running on a Darwin host, this uses the native
/// SDK installed on the system via `xcrun`. When cross-compiling from
/// a non-Darwin host, it falls back to Zig's bundled Darwin headers.
pub fn addPaths(
    b: *std.Build,
    step: *std.Build.Step.Compile,
) !void {
    const target = step.rootModuleTarget();

    // A three paragraph comment to describe a single C macro. Strap in.
    //
    // Zig uses its own libc++ headers when compiling C++. In Zig 0.16,
    // `__config` skips `__config_site`, the file that normally contains
    // platform settings, and expects those settings as `-D` flags:
    // https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/libcxx/include/__config#L13
    //
    // This macro enables Apple's availability checks. Without them, libc++
    // assumes every symbol declared by these newer headers also exists in the
    // target's runtime library:
    // https://github.com/llvm/llvm-project/blob/llvmorg-21.1.0/libcxx/include/__configuration/availability.h#L63-L125
    //
    // For example, `hash.h` either calls `std::__hash_memory` from the runtime
    // library or compiles an inline fallback:
    // https://github.com/llvm/llvm-project/blob/llvmorg-21.1.0/libcxx/include/__functional/hash.h#L244-L250
    // Without the checks, it chooses the runtime symbol. Older macOS versions
    // don't have that symbol, so dyld aborts at launch:
    // https://github.com/llvm/llvm-project/issues/155531
    step.root_module.addCMacro(
        "_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS",
        "1",
    );

    switch (try pathsForTarget(b, target)) {
        .native => |native| {
            step.setLibCFile(native.libc);

            // This is only necessary until this bug is fixed:
            // https://github.com/ziglang/zig/issues/24024
            step.root_module.addSystemFrameworkPath(.{ .cwd_relative = native.framework });
            step.root_module.addSystemIncludePath(.{ .cwd_relative = native.system_include });
            step.root_module.addLibraryPath(.{ .cwd_relative = native.library });
        },
        .cross => |cross| {
            step.setLibCFile(cross.libc);
        },
    }
}
