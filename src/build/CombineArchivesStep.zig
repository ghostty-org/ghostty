//! Combines multiple static archives into a single fat archive.
//! Uses libtool on Darwin and a cross-platform MRI-script build tool
//! on all other platforms (including Windows).
const std = @import("std");
const builtin = @import("builtin");
const LibtoolStep = @import("LibtoolStep.zig");

/// Combine multiple static archives into a single fat archive.
///
/// `name` identifies the library (e.g. "ghostty-internal", "ghostty-vt").
/// Output uses a `-fat` suffix to distinguish the combined archive from
/// the single-library archive in the build cache.
pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    sources: []const std.Build.LazyPath,
) struct { step: *std.Build.Step, output: std.Build.LazyPath } {
    if (target.result.os.tag.isDarwin() and
        comptime builtin.os.tag.isDarwin())
    {
        const libtool = LibtoolStep.create(b, .{
            .name = name,
            .out_name = b.fmt("lib{s}-fat.a", .{name}),
            .sources = @constCast(sources),
        });
        return .{ .step = libtool.step, .output = libtool.output };
    }

    // On non-Darwin, use a build tool that generates an MRI script and
    // pipes it to `zig ar -M`. This works on all platforms including
    // Windows (the previous /bin/sh approach did not).
    const tool = b.addExecutable(.{
        .name = "combine_archives",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/combine_archives.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addArg(b.graph.zig_exe);
    const out_name = if (target.result.os.tag == .windows)
        b.fmt("{s}-fat.lib", .{name})
    else
        b.fmt("lib{s}-fat.a", .{name});
    const output = run.addOutputFileArg(out_name);
    for (sources) |source| run.addFileArg(source);

    return .{ .step = &run.step, .output = output };
}
