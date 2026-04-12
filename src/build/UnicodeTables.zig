const UnicodeTables = @This();

const std = @import("std");
const Config = @import("Config.zig");

/// The exe.
props_exe: ?*std.Build.Step.Compile,
symbols_exe: ?*std.Build.Step.Compile,

/// The output path for the unicode tables
props_output: std.Build.LazyPath,
symbols_output: std.Build.LazyPath,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    uucode_tables: std.Build.LazyPath,
) !UnicodeTables {
    const props_exe, const symbols_exe = if (cfg.emit_unicode_table_gen) exes: {
        const props = b.addExecutable(.{
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

        const symbols = b.addExecutable(.{
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
            inline for (&.{ props, symbols }) |exe| {
                exe.root_module.addImport("uucode", dep.module("uucode"));
            }
        }

        break :exes .{ props, symbols };
    } else .{ null, null };

    return .{
        .props_exe = props_exe,
        .symbols_exe = symbols_exe,
        .props_output = b.path("src/unicode/generated_props.zig"),
        .symbols_output = b.path("src/unicode/generated_symbols.zig"),
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
    if (self.props_exe) |exe| b.installArtifact(exe);
    if (self.symbols_exe) |exe| b.installArtifact(exe);
}
