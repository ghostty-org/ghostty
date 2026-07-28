//! Helpers for invoking Apple's native linker through the target SDK.
//!
//! Callers provide all artifact-specific flags, inputs, and outputs.

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;

/// Returns true when the host Apple toolchain can link the target.
///
/// This is limited to targets covered by the SDK and target-triple mappings
/// below. Add other Darwin platforms alongside support for those mappings.
pub fn available(target: std.Build.ResolvedTarget) bool {
    if (!builtin.os.tag.isDarwin()) return false;

    return switch (target.result.os.tag) {
        .macos, .ios => true,
        else => false,
    };
}

/// Create an Apple Clang link command configured for the target SDK and
/// deployment version. The caller supplies the artifact-specific link flags,
/// inputs, and output.
pub fn addCommand(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
) !*RunStep {
    if (!available(target)) return error.AppleNativeLinkerUnavailable;

    const run = RunStep.create(b, name);
    run.addArgs(&.{
        "/usr/bin/xcrun",
        "--sdk",
        try sdkName(target),
        "clang",
        "-fuse-ld=ld",
        "-target",
        try clangTarget(b, target),
    });
    return run;
}

fn sdkName(target: std.Build.ResolvedTarget) ![]const u8 {
    return switch (target.result.os.tag) {
        .macos => "macosx",
        .ios => switch (target.result.abi) {
            .simulator => "iphonesimulator",
            else => "iphoneos",
        },
        else => error.UnsupportedAppleTarget,
    };
}

fn clangTarget(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ![]const u8 {
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => return error.UnsupportedAppleArchitecture,
    };
    const minimum = target.query.os_version_min orelse
        return error.AppleDeploymentTargetMissing;

    return switch (target.result.os.tag) {
        .macos => b.fmt(
            "{s}-apple-macosx{f}",
            .{ arch, minimum.semver },
        ),
        .ios => switch (target.result.abi) {
            .simulator => b.fmt(
                "{s}-apple-ios{f}-simulator",
                .{ arch, minimum.semver },
            ),
            else => b.fmt(
                "{s}-apple-ios{f}",
                .{ arch, minimum.semver },
            ),
        },
        else => error.UnsupportedAppleTarget,
    };
}
