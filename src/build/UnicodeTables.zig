const UnicodeTables = @This();

const std = @import("std");
const Config = @import("Config.zig");

/// The exe.
exe: *std.Build.Step.Compile,

/// The run artifact for the exe.
run: *std.Build.Step.Run,

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

    if (b.lazyDependency("zg", .{
        .target = b.graph.host,
    })) |dep| {
        exe.root_module.addImport("Graphemes", dep.module("Graphemes"));
        exe.root_module.addImport("DisplayWidth", dep.module("DisplayWidth"));
    }

    // Only used if we're building the old unicode tables
    if (b.lazyDependency("ziglyph", .{
        .target = b.graph.host,
    })) |dep| {
        exe.root_module.addImport("ziglyph", dep.module("ziglyph"));
    }

    const run = b.addRunArtifact(exe);

    return .{
        .exe = exe,
        .run = run,
        .output = run.captureStdOut(),
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
