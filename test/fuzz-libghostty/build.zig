const std = @import("std");
const afl = @import("afl");

/// Possible fuzz targets. Each fuzz target is implemented in
/// src/fuzz_<name>.zig and has an initial corpus in corpus/<name>-initial.
const Fuzzer = struct {
    name: []const u8,

    pub fn source(comptime self: Fuzzer) []const u8 {
        return "src/fuzz_" ++ self.name ++ ".zig";
    }

    pub fn corpus(comptime self: Fuzzer) []const u8 {
        // Change this suffix to use cmin vs initial corpus
        return "corpus/" ++ self.name ++ "-cmin";
    }
};

const fuzzers: []const Fuzzer = &.{
    .{ .name = "parser" },
    .{ .name = "stream" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty_dep = b.lazyDependency("ghostty", .{
        .simd = false,
    });

    inline for (fuzzers) |fuzzer| {
        const run_step = b.step(
            b.fmt("run-{s}", .{fuzzer.name}),
            b.fmt("Run {s} with afl-fuzz", .{fuzzer.name}),
        );

        const lib_mod = b.createModule(.{
            .root_source_file = b.path(fuzzer.source()),
            .target = target,
            .optimize = optimize,
        });
        if (ghostty_dep) |dep| {
            lib_mod.addImport(
                "ghostty-vt",
                dep.module("ghostty-vt"),
            );
        }

        const lib = b.addLibrary(.{
            .name = fuzzer.name,
            .root_module = lib_mod,
        });
        lib.root_module.stack_check = false;
        lib.root_module.fuzz = true;

        const exe = afl.addInstrumentedExe(b, lib);
        const run = afl.addFuzzerRun(
            b,
            exe,
            b.path(fuzzer.corpus()),
            b.path(b.fmt("afl-out/{s}", .{fuzzer.name})),
        );
        run_step.dependOn(&run.step);

        const exe_install = b.addInstallBinFile(
            exe,
            "fuzz-" ++ fuzzer.name,
        );
        b.getInstallStep().dependOn(&exe_install.step);
    }
}
