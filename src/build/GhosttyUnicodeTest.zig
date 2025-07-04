const UnicodeTest = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const UnicodeTables = @import("UnicodeTables.zig");

/// The unicode test executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !UnicodeTest {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "unicode-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.strip,
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
    });
    const install_step = b.addInstallArtifact(exe, .{});

    // Add the shared dependencies
    _ = try deps.add(exe);

    // Add ziglyph just for unicode-test
    if (b.lazyDependency("ziglyph", .{
        .target = cfg.target,
        .optimize = cfg.optimize,
    })) |dep| {
        exe.root_module.addImport("ziglyph", dep.module("ziglyph"));
    }

    // Add the old version of the unicode tables
    const old_unicode_tables = try UnicodeTables.init(b);
    old_unicode_tables.run.addArg("old");

    old_unicode_tables.output.addStepDependencies(&exe.step);
    exe.root_module.addAnonymousImport("old_unicode_tables", .{
        .root_source_file = old_unicode_tables.output,
    });

    return .{
        .exe = exe,
        .install_step = install_step,
    };
}

/// Add the unicode test exe to the install target.
pub fn install(self: *const UnicodeTest) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
