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

    /// The libraries to bundle
    libraries: []const Library,
};

/// A single library to bundle into the xcframework.
pub const Library = struct {
    /// Library file (dylib, a) to package.
    library: LazyPath,

    /// Path to a directory with the headers.
    headers: LazyPath,
};

step: *Step,

output: LazyPath,

pub fn create(b: *std.Build, opts: Options) *XCFrameworkStep {
    const self = b.allocator.create(XCFrameworkStep) catch @panic("OOM");

    // Then we run xcodebuild to create the framework.
    const run_create, const run_output = run: {
        const run = RunStep.create(b, b.fmt("xcframework {s}", .{opts.name}));
        run.addArgs(&.{ "xcodebuild", "-create-xcframework" });
        for (opts.libraries) |lib| {
            run.addArg("-library");
            run.addFileArg(lib.library);
            run.addArg("-headers");
            run.addDirectoryArg(lib.headers);
        }
        run.addArg("-output");
        const output = run.addOutputDirectoryArg(b.fmt(
            "{s}.xcframework",
            .{opts.name},
        ));
        run.expectExitCode(0);
        break :run .{ run, output };
    };

    self.* = .{
        .step = &run_create.step,
        .output = run_output,
    };

    return self;
}
