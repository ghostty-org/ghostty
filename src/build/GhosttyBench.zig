//! GhosttyBench generates all the Ghostty benchmark helper binaries.
const GhosttyBench = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

steps: []*std.Build.Step.Compile,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyBench {
    var steps = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    errdefer steps.deinit();

    // Our synthetic data generator
    {
        const exe = b.addExecutable(.{
            .name = "ghostty-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_gen.zig"),
                .target = deps.config.target,
                // We always want our datagen to be fast because it
                // takes awhile to run.
                .optimize = .ReleaseFast,
            }),
        });
        exe.linkLibC();
        _ = try deps.add(exe);
        try steps.append(exe);
    }

    // Our benchmarking application.
    {
        const exe = b.addExecutable(.{
            .name = "ghostty-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_bench.zig"),
                .target = deps.config.target,
                // We always want our benchmarks to be in release mode.
                .optimize = .ReleaseFast,
            }),
        });
        exe.linkLibC();
        _ = try deps.add(exe);
        try steps.append(exe);
    }

    return .{ .steps = steps.items };
}

pub fn install(self: *const GhosttyBench) void {
    const b = self.steps[0].step.owner;
    for (self.steps) |step| b.installArtifact(step);
}
