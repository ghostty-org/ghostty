const std = @import("std");
const builtin = @import("builtin");

/// Creates a build step that produces an AFL++-instrumented fuzzing
/// executable.
///
/// Returns a `LazyPath` to the resulting fuzzing executable.
pub fn addInstrumentedExe(
    b: *std.Build,
    obj: *std.Build.Step.Compile,
) std.Build.LazyPath {
    const pkg = b.dependencyFromBuildZig(
        @This(),
        .{},
    );

    const afl_cc = b.addSystemCommand(&.{
        b.findProgram(&.{"afl-cc"}, &.{}) catch
            @panic("Could not find 'afl-cc', which is required to build"),
        "-O3",
    });
    if (builtin.target.os.tag.isDarwin()) {
        // Apple's newer ld asserts on the custom section names emitted by
        // AFL's LLVM instrumentation when linking our Zig-produced bitcode.
        // lld links the same inputs without issue.
        afl_cc.addArg("-fuse-ld=lld");
    }
    afl_cc.addArg("-o");
    const fuzz_exe = afl_cc.addOutputFileArg(obj.name);
    afl_cc.addFileArg(pkg.path("afl.c"));
    afl_cc.addFileArg(obj.getEmittedLlvmBc());

    // The LLVM bitcode only contains the Zig code in the compilation.
    // C source files in the module graph are compiled to native objects
    // that live only in the static archive, so link the archive after
    // the bitcode to resolve those symbols. The archive members holding
    // the Zig code are never pulled in (and so can't conflict) because
    // the bitcode object already defines every symbol they provide.
    // Those C objects are built with UBSan in debug modes and we link
    // with an external compiler that doesn't provide Zig's ubsan
    // runtime, so it must be bundled. The ubsan runtime uses f128
    // conversion builtins that the external compiler's runtime may not
    // provide (e.g. Apple's), so Zig's compiler-rt must be bundled too.
    // The archive members must also be built as PIC since external
    // compilers typically default to PIE executables.
    obj.bundle_ubsan_rt = true;
    obj.bundle_compiler_rt = true;
    obj.root_module.pic = true;
    afl_cc.addFileArg(obj.getEmittedBin());

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
    return run;
}

// Required so `zig build` works although it does nothing.
pub fn build(b: *std.Build) !void {
    _ = b;
}
