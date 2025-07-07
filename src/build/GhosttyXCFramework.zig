const GhosttyXCFramework = @This();

const std = @import("std");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyLib = @import("GhosttyLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");

xcframework: *XCFrameworkStep,
copy: *std.Build.Step,

target: Target,

pub const Target = enum { native, universal };

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

            // We force the Apple CPU model because the simulator
            // doesn't support the generic CPU model as of Zig 0.14 due
            // to missing "altnzcv" instructions, which is false. This
            // surely can't be right but we can fix this if/when we get
            // back to running simulator builds.
            .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a17 },
        }),
    ));

    // The xcframework wraps our ghostty library so that we can link
    // it to the final app built with Swift.
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "GhosttyKit",
        .libraries = switch (target) {
            .universal => &.{
                .{
                    .library = macos_universal.output,
                    .headers = b.path("include"),
                },
                .{
                    .library = ios.output,
                    .headers = b.path("include"),
                },
                .{
                    .library = ios_sim.output,
                    .headers = b.path("include"),
                },
            },

            .native => &.{.{
                .library = macos_native.output,
                .headers = b.path("include"),
            }},
        },
    });

    // A command to copy the xcframework to the output directory,
    // because the xcode project needs a stable path.
    const copy = copy: {
        const remove = RunStep.create(b, "remove old xcframework");
        remove.has_side_effects = true;
        remove.cwd = b.path("");
        remove.addArgs(&.{
            "rm",
            "-rf",
            "macos/GhosttyKit.xcframework",
        });
        remove.expectExitCode(0);

        const step = RunStep.create(b, "copy xcframework");
        step.has_side_effects = true;
        step.cwd = b.path("");
        step.addArgs(&.{ "cp", "-R" });
        step.addDirectoryArg(xcframework.output);
        step.addArg("macos/GhosttyKit.xcframework");
        step.step.dependOn(&remove.step);
        break :copy step;
    };

    return .{
        .xcframework = xcframework,
        .copy = &copy.step,
        .target = target,
    };
}

pub fn install(self: *const GhosttyXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.copy);
}
