const std = @import("std");
const builtin = @import("builtin");
const apple_sdk = @import("apple_sdk");
const translate_c = @import("translate_c");

const Framework = struct {
    const Tag = enum { all, macos };

    tag: Tag,
    name: []const u8,
    headers: []const []const u8,
};

const frameworks = [_]Framework{
    .{ .tag = .all, .name = "CoreFoundation", .headers = &.{"CoreFoundation.h"} },
    .{ .tag = .all, .name = "CoreGraphics", .headers = &.{"CoreGraphics.h"} },
    .{ .tag = .all, .name = "CoreText", .headers = &.{"CoreText.h"} },
    .{ .tag = .all, .name = "CoreVideo", .headers = &.{ "CoreVideo.h", "CVPixelBuffer.h" } },
    .{ .tag = .all, .name = "QuartzCore", .headers = &.{"CALayer.h"} },
    .{ .tag = .all, .name = "IOSurface", .headers = &.{"IOSurfaceRef.h"} },
    .{ .tag = .macos, .name = "Carbon", .headers = &.{"Carbon.h"} },
};

const extra_headers = [_][]const u8{
    "dispatch/dispatch.h",
    "os/log.h",
    "os/signpost.h",
};

fn includeFiles(b: *std.Build, tag: Framework.Tag) ![]translate_c.Options.IncludeFile {
    var len: usize = 0;
    for (frameworks) |framework| {
        if (tag != .macos and framework.tag == .macos) continue;
        len += framework.headers.len;
    }
    len += extra_headers.len;
    var includes_builder: std.ArrayList(translate_c.Options.IncludeFile) =
        try .initCapacity(b.allocator, len);

    for (frameworks) |framework| {
        if (tag != .macos and framework.tag == .macos) continue;
        for (framework.headers) |h| {
            const path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ framework.name, h });
            includes_builder.appendAssumeCapacity(.{ .path = path });
        }
    }

    for (extra_headers) |h| includes_builder.appendAssumeCapacity(.{ .path = h });

    return includes_builder.items;
}

fn linkFrameworks(tag: Framework.Tag, module: *std.Build.Module) !void {
    for (frameworks) |framework| {
        if (tag != .macos and framework.tag == .macos) continue;
        module.linkFramework(framework.name, .{});
    }
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("macos", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    try translate_c.addImportToModule(b, "macos_c", module, .{
        .source = .{ .includes = .{ .files = try includeFiles(
            b,
            if (target.result.os.tag == .macos) .macos else .all,
        ) } },
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "macos",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    lib.root_module.addCSourceFile(.{
        .file = b.path("os/zig_macos.c"),
        .flags = &.{"-std=c99"},
    });
    lib.root_module.addCSourceFile(.{
        .file = b.path("text/ext.c"),
    });

    inline for (.{ lib.root_module, module }) |mod| {
        try linkFrameworks(if (target.result.os.tag == .macos) .macos else .all, mod);
    }
    try apple_sdk.addPaths(b, lib);
    b.installArtifact(lib);

    {
        const test_exe = b.addTest(.{
            .name = "test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        if (target.result.os.tag.isDarwin()) {
            try apple_sdk.addPaths(b, test_exe);
        }
        test_exe.root_module.linkLibrary(lib);

        var it = module.import_table.iterator();
        while (it.next()) |entry| {
            test_exe.root_module.addImport(
                entry.key_ptr.*,
                entry.value_ptr.*,
            );
        }

        b.installArtifact(test_exe);

        const tests_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }
}
