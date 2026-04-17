const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("opengl", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(b.path("../../vendor/glad/include"));

    const c = b.addTranslateC(.{
        .root_source_file = b.path("c_import.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(b.path("../../vendor/glad/include"));
    module.addImport("c", c.createModule());
}
