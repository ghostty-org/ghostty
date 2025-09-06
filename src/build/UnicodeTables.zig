const UnicodeTables = @This();

const std = @import("std");
const Config = @import("Config.zig");

/// The exe.
props_exe: *std.Build.Step.Compile,
symbols_exe: *std.Build.Step.Compile,

/// The output path for the unicode tables
props_output: std.Build.LazyPath,
symbols_output: std.Build.LazyPath,

pub fn init(b: *std.Build) !UnicodeTables {
    const props_exe = b.addExecutable(.{
        .name = "props-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/props.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });

    const symbols_exe = b.addExecutable(.{
        .name = "symbols-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/symbols.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });

    if (b.lazyDependency("ziglyph", .{
        .target = b.graph.host,
    })) |ziglyph_dep| {
        inline for (&.{ props_exe, symbols_exe }) |exe| {
            exe.root_module.addImport(
                "ziglyph",
                ziglyph_dep.module("ziglyph"),
            );
        }
    }

    const props_run = b.addRunArtifact(props_exe);
    const symbols_run = b.addRunArtifact(symbols_exe);

    return .{
        .props_exe = props_exe,
        .symbols_exe = symbols_exe,
        .props_output = props_run.captureStdOut(),
        .symbols_output = symbols_run.captureStdOut(),
    };
}

/// Add the "unicode_tables" import.
pub fn addImport(self: *const UnicodeTables, step: *std.Build.Step.Compile) void {
    self.props_output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("unicode_tables", .{
        .root_source_file = self.props_output,
    });
    self.symbols_output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("symbols_tables", .{
        .root_source_file = self.symbols_output,
    });
}

/// Install the exe
pub fn install(self: *const UnicodeTables, b: *std.Build) void {
    b.installArtifact(self.props_exe);
    b.installArtifact(self.symbols_exe);
}
