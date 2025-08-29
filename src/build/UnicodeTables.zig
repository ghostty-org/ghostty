const UnicodeTables = @This();

const std = @import("std");
const Config = @import("Config.zig");

/// The exe.
exe: *std.Build.Step.Compile,

/// The output path for the unicode tables
output: std.Build.LazyPath,

pub fn init(b: *std.Build) !UnicodeTables {
    const exe = b.addExecutable(.{
        .name = "unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/props.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });

    if (b.lazyDependency("ziglyph", .{
        .target = b.graph.host,
    })) |ziglyph_dep| {
        exe.root_module.addImport(
            "ziglyph",
            ziglyph_dep.module("ziglyph"),
        );
    }

    const run = b.addRunArtifact(exe);

    // FIXME: Workaround for a Zig 0.15 regression
    // https://github.com/ziglang/zig/issues/24957
    const wf = b.addWriteFiles();
    const output = wf.addCopyFile(run.captureStdOut(), "unicode_tables.zig");

    return .{
        .exe = exe,
        .output = output,
    };
}

/// Add the "unicode_tables" import.
pub fn addImport(self: *const UnicodeTables, step: *std.Build.Step.Compile) void {
    self.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("unicode_tables", .{
        .root_source_file = self.output,
    });
}

/// Install the exe
pub fn install(self: *const UnicodeTables, b: *std.Build) void {
    b.installArtifact(self.exe);
}
