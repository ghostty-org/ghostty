//! A zig builder step that runs "swift build" in the context of
//! a Swift project managed with SwiftPM. This is primarily meant to build
//! executables currently since that is what we build.
const XCFrameworkStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// The name of the xcframework to create.
    name: []const u8,

    /// The path to write the framework
    out_path: union(enum) {
        /// Write into the install prefix
        install_prefix: []const u8,

        /// Write directly into the source tree. Used by e.g. GhosttyKit
        /// which can then be integrated with the Swift code.
        source_tree: []const u8,
    },

    /// The libraries to bundle
    libraries: []const Library,
};

/// A single library to bundle into the xcframework.
pub const Library = struct {
    /// Library file (dylib, a) to package.
    library: LazyPath,

    /// Path to a directory with the headers.
    headers: LazyPath,

    /// Path to a debug symbols file (.dSYM) if available.
    dsym: ?LazyPath,
};

step: *Step,

pub fn create(b: *std.Build, opts: Options) *XCFrameworkStep {
    const self = b.allocator.create(XCFrameworkStep) catch @panic("OOM");

    // xcodebuild refuses to overwrite an existing xcframework, so we
    // always remove the previous one first.
    const delete = RunStep.create(b, b.fmt("xcframework delete {s}", .{opts.name}));
    delete.has_side_effects = true;
    delete.addArgs(&.{ "rm", "-rf" });
    // Writes directly to the final location rather than into the cache.
    addOutPathArg(b, delete, opts.out_path);

    const run = RunStep.create(b, b.fmt("xcframework {s}", .{opts.name}));
    run.has_side_effects = true;
    run.addArgs(&.{ "xcodebuild", "-create-xcframework" });
    for (opts.libraries) |lib| {
        run.addArg("-library");
        run.addFileArg(lib.library);
        run.addArg("-headers");
        run.addDirectoryArg(lib.headers);
        if (lib.dsym) |dsym| {
            run.addArg("-debug-symbols");
            run.addDirectoryArg(dsym);
        }
    }
    run.addArg("-output");
    addOutPathArg(b, run, opts.out_path);
    run.expectExitCode(0);
    _ = run.captureStdOut(.{});
    _ = run.captureStdErr(.{});
    run.step.dependOn(&delete.step);

    self.* = .{
        .step = &run.step,
    };

    return self;
}

/// Adds the output path as an argument. The install prefix is only
/// known when the step runs, so it is passed as a lazy path.
fn addOutPathArg(
    b: *std.Build,
    run: *RunStep,
    out_path: @FieldType(Options, "out_path"),
) void {
    switch (out_path) {
        .install_prefix => |v| run.addDirectoryArg(b.graph.path(.install_prefix, v)),
        .source_tree => |v| run.addArg(v),
    }
}
