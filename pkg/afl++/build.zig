const std = @import("std");

/// Creates a build step that produces an AFL++-instrumented fuzzing
/// executable.
///
/// Returns a `LazyPath` to the resulting fuzzing executable.
pub fn addInstrumentedExe(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
) std.Build.LazyPath {
    // Force the build system to produce the binary artifact even though we
    // only consume the LLVM bitcode below. Without this, the dependency
    // tracking doesn't wire up correctly.
    _ = obj.getEmittedBin();

    const pkg = b.dependencyFromBuildZig(
        @This(),
        .{},
    );

    const afl_cc = b.addSystemCommand(&.{
        b.findProgram(&.{"afl-cc"}, &.{}) catch
            @panic("Could not find 'afl-cc', which is required to build"),
        "-O3",
    });
    afl_cc.addArg("-o");
    const fuzz_exe = afl_cc.addOutputFileArg(obj.name);
    afl_cc.addFileArg(pkg.path("afl.c"));
    afl_cc.addFileArg(obj.getEmittedLlvmBc());
    return fuzz_exe;
}

/// Creates a run step that invokes `afl-fuzz` with the given instrumented
/// executable, input corpus directory, and output directory.
///
/// Returns the `Run` step so callers can wire it into a build step.
pub fn addFuzzerRun(
    b: *std.Build,
    exe: std.Build.LazyPath,
    corpus_dir: std.Build.LazyPath,
    output_dir: std.Build.LazyPath,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        b.findProgram(&.{"afl-fuzz"}, &.{}) catch
            @panic("Could not find 'afl-fuzz', which is required to run"),
        "-i",
    });
    run.addDirectoryArg(corpus_dir);
    run.addArgs(&.{"-o"});
    run.addDirectoryArg(output_dir);
    run.addArgs(&.{"--"});
    run.addFileArg(exe);
    run.addArgs(&.{"@@"});
    return run;
}

// Required so `zig build` works although it does nothing.
pub fn build(b: *std.Build) !void {
    _ = b;
}
