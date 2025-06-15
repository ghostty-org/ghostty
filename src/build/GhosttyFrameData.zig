//! GhosttyFrameData generates a compressed file and zig module which contains (and exposes) the
//! Ghostty animation frames for use in `ghostty +boo`
const GhosttyFrameData = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The exe.
exe: *std.Build.Step.Compile,

/// The output path for the compressed framedata zig file
output: std.Build.LazyPath,

pub fn init(b: *std.Build) !GhosttyFrameData {
    const exe = b.addExecutable(.{
        .name = "framegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/framegen/main.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });

    const run = b.addRunArtifact(exe);

    _ = run.addOutputFileArg("framedata.compressed");
    return .{
        .exe = exe,
        .output = run.captureStdOut(),
    };
}

/// Add the "framedata" import.
pub fn addImport(self: *const GhosttyFrameData, step: *std.Build.Step.Compile) void {
    self.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("framedata", .{
        .root_source_file = self.output,
    });
}
