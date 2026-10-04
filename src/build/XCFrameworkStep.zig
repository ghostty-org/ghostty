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
        /// Copy the generated xcframework into the install prefix
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

    const run = RunStep.create(b, b.fmt("xcframework {s}", .{opts.name}));
    run.has_side_effects = true;
    run.addArgs(&.{ "xcodebuild", "-create-xcframework" });
    for (opts.libraries) |lib| {
        run.addArg("-library");
        run.addFileArg(lib.library);
        run.addArg("-headers");
        run.addFileArg(lib.headers);
        if (lib.dsym) |dsym| {
            run.addArg("-debug-symbols");
            run.addFileArg(dsym);
        }
    }
    run.addArg("-output");
    const out = run.addOutputFileArg2("xcframework", .{});
    run.expectExitCode(0);
    _ = run.captureStdOut(.{});
    _ = run.captureStdErr(.{});

    const step = switch (opts.out_path) {
        .install_prefix => |v| s: {
            const install_step = b.addInstallFile(out, v);
            break :s &install_step.step;
        },
        .source_tree => |v| s: {
            // This is a rather cursed use of UpdateSourceFiles, but I'm
            // not really interested in redesigning the macOS build system
            const usf = b.addUpdateSourceFiles();
            usf.addCopyFileToSource(out, v);
            break :s &usf.step;
        },
    };

    self.* = .{
        .step = step,
    };

    return self;
}
