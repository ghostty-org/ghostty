//! A zig builder step that runs "libtool" against a list of libraries
//! in order to create a single combined static library.
const LibtoolStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// The name of this step.
    name: []const u8,

    /// The filename (not the path) of the file to create. This will
    /// be placed in a unique hashed directory. Use out_path to access.
    out_name: []const u8,

    /// Library files (.a) to combine.
    sources: []LazyPath,
};

/// The step to depend on.
step: *Step,

/// The output file from the libtool run.
output: LazyPath,

/// Run libtool against a list of library files to combine into a single
/// static library.
pub fn create(b: *std.Build, opts: Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");

    const run_step = RunStep.create(b, b.fmt("libtool {s}", .{opts.name}));
    run_step.addArgs(&.{ "libtool", "-static", "-o" });
    const output = run_step.addOutputFileArg(opts.out_name);
    for (opts.sources, 0..) |source, i| {
        run_step.addFileArg(normalizeArchive(
            b,
            opts.name,
            opts.out_name,
            i,
            source,
        ));
    }

    self.* = .{
        .step = &run_step.step,
        .output = output,
    };

    return self;
}

fn normalizeArchive(
    b: *std.Build,
    step_name: []const u8,
    out_name: []const u8,
    index: usize,
    source: LazyPath,
) LazyPath {
    // Newer Xcode libtool can drop 64-bit archive members if the input
    // archive layout doesn't match what it expects. ranlib rewrites the
    // archive without flattening members through the filesystem, so we
    // normalize each source archive first. This is a Zig/toolchain
    // interoperability workaround, not a Ghostty archive format change.
    const run_step = RunStep.create(
        b,
        b.fmt("ranlib {s} #{d}", .{ step_name, index }),
    );
    run_step.addArgs(&.{
        "/bin/sh",
        "-c",
        "/bin/cp \"$1\" \"$2\" && /usr/bin/ranlib \"$2\"",
        "_",
    });
    run_step.addFileArg(source);
    return run_step.addOutputFileArg(b.fmt("{d}-{s}", .{ index, out_name }));
}
