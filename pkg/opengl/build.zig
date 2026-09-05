const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c = b.addTranslateC(.{
        .root_source_file = b.path("gl.c"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(b.path("../../vendor/glad/include"));

    const module = b.addModule("opengl", .{ .root_source_file = b.path("main.zig") });
    module.addImport("c", c.createModule());
}
