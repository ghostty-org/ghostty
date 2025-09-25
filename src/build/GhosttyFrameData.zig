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
    // TODO: Restore this when Zig's stdlib adds compression functionality back
    //
    // Zig 0.15 removed all compression capabilities as a direct casualty of
    // Writergate. For now we just pre-compress the framedata and commit it to
    // the repo, but we should definitely do it the "proper" way once Zig figures
    // it out again.

    // const exe = b.addExecutable(.{
    //     .name = "framegen",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/build/framegen/main.zig"),
    //         .target = b.graph.host,
    //         .strip = false,
    //         .omit_frame_pointer = false,
    //         .unwind_tables = .sync,
    //     }),
    // });

    // const run = b.addRunArtifact(exe);
    // // Both the compressed framedata and the Zig source file
    // // have to be put in the same directory, since the compressed file
    // // has to be within the source file's include path.
    // const dir = run.addOutputDirectoryArg("framedata");

    return .{
        // .exe = exe,
        // .output = dir.path(b, "framedata.zig"),
        .exe = undefined,
        .output = b.path("src/build/framegen/framedata.compressed"),
    };
}

/// Add the "framedata" import.
pub fn addImport(self: *const GhosttyFrameData, step: *std.Build.Step.Compile) void {
    self.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("framedata", .{
        .root_source_file = self.output,
    });
}
