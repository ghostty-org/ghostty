const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = target;
    _ = optimize;
}

/// Setup the step to point to the proper Apple SDK for libc and
/// frameworks. This expects and relies on the native SDK being
/// installed on the system. Ghostty doesn't support cross-compilation
/// for Apple platforms.
pub fn addPaths(
    b: *std.Build,
    step: *std.Build.Step.Compile,
) !void {
    // The cache. This always uses b.allocator and never frees memory
    // (which is idiomatic for a Zig build exe). We cache the libc txt
    // file we create because it is expensive to generate (subprocesses).
    const Cache = struct {
        const Key = struct {
            arch: std.Target.Cpu.Arch,
            os: std.Target.Os.Tag,
            abi: std.Target.Abi,
        };

        var map: std.AutoHashMapUnmanaged(Key, ?struct {
            libc: std.Build.LazyPath,
            framework: []const u8,
            system_include: []const u8,
            library: []const u8,
        }) = .{};
    };

    const target = step.rootModuleTarget();
    const gop = try Cache.map.getOrPut(b.allocator, .{
        .arch = target.cpu.arch,
        .os = target.os.tag,
        .abi = target.abi,
    });

    if (!gop.found_existing) {
        // Detect our SDK using the "findNative" Zig stdlib function.
        // This is really important because it forces using `xcrun` to
        // find the SDK path.
        const libc = try std.zig.LibCInstallation.findNative(.{
            .allocator = b.allocator,
            .target = &step.rootModuleTarget(),
            .verbose = false,
        });

        // Render the file compatible with the `--libc` Zig flag.
        var stream: std.io.Writer.Allocating = .init(b.allocator);
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

        gop.value_ptr.* = .{
            .libc = path,
            .framework = framework_path,
            .system_include = libc.sys_include_dir.?,
            .library = library_path,
        };
    }

    const value = gop.value_ptr.* orelse return switch (target.os.tag) {
        // Return a more descriptive error. Before we just returned the
        // generic error but this was confusing a lot of community members.
        // It costs us nothing in the build script to return something better.
        .macos => error.XcodeMacOSSDKNotFound,
        .ios => error.XcodeiOSSDKNotFound,
        .tvos => error.XcodeTVOSSDKNotFound,
        .watchos => error.XcodeWatchOSSDKNotFound,
        else => error.XcodeAppleSDKNotFound,
    };

    step.setLibCFile(value.libc);

    // This is only necessary until this bug is fixed:
    // https://github.com/ziglang/zig/issues/24024
    step.root_module.addSystemFrameworkPath(.{ .cwd_relative = value.framework });
    step.root_module.addSystemIncludePath(.{ .cwd_relative = value.system_include });
    step.root_module.addLibraryPath(.{ .cwd_relative = value.library });
}
