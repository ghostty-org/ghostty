const GhosttyXCFramework = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyLib = @import("GhosttyLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;

target: Target,
swift_build: *std.Build.Step.Run,
swift_test: *std.Build.Step.Run,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyXCFramework {
    // Universal macOS build
    const macos_universal = try GhosttyLib.initMacOSUniversal(b, deps);

    // Native macOS build
    const macos_native = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));

    // iOS
    const ios = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .ios,
            .os_version_min = Config.osVersionMin(.ios),
            .abi = null,
        }),
    ));

    // iOS Simulator
    const ios_sim = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .ios,
            .os_version_min = Config.osVersionMin(.ios),
            .abi = .simulator,
            .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a17 },
        }),
    ));

    // The xcframework wraps our ghostty library so that we can link
    // it to the swift package built with Swift.
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "CGhosttyKit",
        .out_path = "macos/CGhosttyKit.xcframework",
        .libraries = switch (target) {
            .universal => &.{
                .{
                    .library = macos_universal.output,
                    .headers = b.path("include"),
                    .dsym = macos_universal.dsym,
                },
                .{
                    .library = ios.output,
                    .headers = b.path("include"),
                    .dsym = ios.dsym,
                },
                .{
                    .library = ios_sim.output,
                    .headers = b.path("include"),
                    .dsym = ios_sim.dsym,
                },
            },

            .native => &.{.{
                .library = macos_native.output,
                .headers = b.path("include"),
                .dsym = macos_native.dsym,
            }},
        },
    });

    // swift build step: Depends on XCFramework
    var swift_build = b.addSystemCommand(&.{ "swift", "build" });
    swift_build.addArgs(&.{
        "--package-path",
        "macos/GhosttyKit",
    });
    swift_build.step.dependOn(xcframework.step);

    // swift test step: Depends on XCFramework
    var swift_test = b.addSystemCommand(&.{ "swift", "test" });
    swift_test.addArgs(&.{
        "--package-path",
        "macos/GhosttyKit",
    });
    swift_test.step.dependOn(xcframework.step);

    return .{
        .target = target,
        .swift_build = swift_build,
        .swift_test = swift_test,
    };
}

pub fn install(self: *const GhosttyXCFramework) void {
    const b = self.swift_build.step.owner;
    b.getInstallStep().dependOn(&self.swift_build.step);
}

pub fn addBuildDependencies(
    self: *const GhosttyXCFramework,
    other_step: *std.Build.Step,
    args: []const []const u8,
) void {
    self.swift_build.addArgs(args);
    other_step.dependOn(&self.swift_build.step);
}

pub fn addTestDependencies(
    self: *const GhosttyXCFramework,
    other_step: *std.Build.Step,
    args: []const []const u8,
) void {
    self.swift_test.addArgs(args);
    other_step.dependOn(&self.swift_test.step);
}
