const std = @import("std");
const afl = @import("afl");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const run_step = b.step("run", "Run the fuzzer with afl-fuzz");

    // Create the C ABI library from Zig source that exports the
    // API that the `afl-cc` main.c entrypoint can call into. This
    // lets us just use standard `afl-cc` to fuzz test our library without
    // needing to write any Zig-specific fuzzing harnesses.
    const lib = lib: {
        // Zig module
        const lib_mod = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        });
        if (b.lazyDependency("ghostty", .{
            .simd = false,
        })) |dep| {
            lib_mod.addImport(
                "ghostty-vt",
                dep.module("ghostty-vt"),
            );
        }

        // C lib
        const lib = b.addLibrary(.{
            .name = "ghostty-fuzz",
            .root_module = lib_mod,
        });

        // Required to build properly with afl-cc
        lib.root_module.stack_check = false;
        lib.root_module.fuzz = true;

        break :lib lib;
    };

    // Build a C entrypoint with afl-cc that links against the generated
    // static Zig library. afl-cc is expected to be on the PATH.
    const exe = afl.addInstrumentedExe(b, lib);

    // Runner to simplify running afl-fuzz.
    // Use the cmin corpus (edge-deduplicated from prior runs) so that each
    // fuzzing session starts from full coverage. Switch to "corpus/initial"
    // if you don't have a cmin corpus yet.
    const run = afl.addFuzzerRun(b, exe, b.path("corpus/vt-parser-cmin"), b.path("afl-out"));

    // Install
    b.installArtifact(lib);
    const exe_install = b.addInstallBinFile(exe, "ghostty-fuzz");
    b.getInstallStep().dependOn(&exe_install.step);

    // Run
    run_step.dependOn(&run.step);
}
