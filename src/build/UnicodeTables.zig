const UnicodeTables = @This();

const std = @import("std");

/// The exe.
props_exe: *std.Build.Step.Compile,
symbols_exe: *std.Build.Step.Compile,

/// The output path for the unicode tables
props_output: std.Build.LazyPath,
symbols_output: std.Build.LazyPath,

pub fn init(b: *std.Build, uucode_tables: std.Build.LazyPath) !UnicodeTables {
    const props_exe = b.addExecutable(.{
        .name = "props-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/props_uucode.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),

        // TODO: x86_64 self-hosted crashes
        .use_llvm = true,
    });

    const symbols_exe = b.addExecutable(.{
        .name = "symbols-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/symbols_uucode.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),

        // TODO: x86_64 self-hosted crashes
        .use_llvm = true,
    });

    if (b.lazyDependency("uucode", .{
        .target = b.graph.host,
        .tables_path = uucode_tables,
        .build_config_path = b.path("src/build/uucode_config.zig"),
    })) |dep| {
        inline for (&.{ props_exe, symbols_exe }) |exe| {
            exe.root_module.addImport("uucode", dep.module("uucode"));
        }
    }

    const props_run = b.addRunArtifact(props_exe);
    const symbols_run = b.addRunArtifact(symbols_exe);

    // Generated Zig files have to end with .zig
    const wf = b.addWriteFiles();
    const props_output = wf.addCopyFile(props_run.captureStdOut(), "props.zig");
    const symbols_output = wf.addCopyFile(symbols_run.captureStdOut(), "symbols.zig");

    return .{
        .props_exe = props_exe,
        .symbols_exe = symbols_exe,
        .props_output = props_output,
        .symbols_output = symbols_output,
    };
}

/// Add the "unicode_tables" import.
pub fn addImport(self: *const UnicodeTables, step: *std.Build.Step.Compile) void {
    self.props_output.addStepDependencies(&step.step);
    self.symbols_output.addStepDependencies(&step.step);
    self.addModuleImport(step.root_module);
}

/// Add the "unicode_tables" import to a module.
pub fn addModuleImport(
    self: *const UnicodeTables,
    module: *std.Build.Module,
) void {
    module.addAnonymousImport("unicode_tables", .{
        .root_source_file = self.props_output,
    });
    module.addAnonymousImport("symbols_tables", .{
        .root_source_file = self.symbols_output,
    });
}

/// Install the exe
pub fn install(self: *const UnicodeTables, b: *std.Build) void {
    b.installArtifact(self.props_exe);
    b.installArtifact(self.symbols_exe);
}
