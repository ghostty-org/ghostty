const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("utf8proc", .{ .root_source_file = .{ .path = "main.zig" } });

    const upstream = b.dependency("utf8proc", .{});
    const lib = b.addLibrary(.{
        .name = "utf8proc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();

    lib.addIncludePath(upstream.path(""));
    module.addIncludePath(upstream.path(""));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.append("-DUTF8PROC_EXPORTS");
    defer flags.deinit();
    lib.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &.{"utf8proc.c"},
        .flags = flags.items,
    });

    lib.installHeadersDirectoryOptions(.{
        .source_dir = upstream.path(""),
        .install_dir = .header,
        .install_subdir = "",
        .include_extensions = &.{".h"},
    });

    b.installArtifact(lib);
}
