const std = @import("std");
const builtin = @import("builtin");
const apple_sdk = @import("apple_sdk");

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

const framework_header_fmt = "#include <{s}/{s}>\n";
const extra_header_fmt = "#include <{s}>\n";

fn cSourceLen(tag: Framework.Tag) usize {
    var len: usize = 0;
    for (frameworks) |framework| {
        if (tag != .macos and framework.tag == .macos) continue;
        for (framework.headers) |h| len += std.fmt.count(framework_header_fmt, .{ framework.name, h });
    }
    for (extra_headers) |h| len += std.fmt.count(extra_header_fmt, .{h});
    return len;
}

fn genCSource(comptime tag: Framework.Tag) [cSourceLen(tag):0]u8 {
    const len = cSourceLen(tag);
    var buf: [len:0]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    for (frameworks) |framework| {
        if (tag != .macos and framework.tag == .macos) continue;
        for (framework.headers) |h| writer.print(framework_header_fmt, .{ framework.name, h }) catch unreachable;
    }
    for (extra_headers) |h| writer.print(extra_header_fmt, .{h}) catch unreachable;
    buf[len] = 0;
    return buf;
}

const c_source_macos = genCSource(.macos);
const c_source_other = genCSource(.all);

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

    translate: {
        const translate_c = b.lazyImport(@This(), "translate_c") orelse break :translate;
        const translate_c_dep = b.lazyDependency("translate_c", .{}) orelse break :translate;
        const macos_c: translate_c.Translator = .init(translate_c_dep, .{
            .c_source_file = b.addWriteFiles().add(
                "macos_c.h",
                if (target.result.os.tag == .macos) &c_source_macos else &c_source_other,
            ),
            .target = target,
            .optimize = optimize,
            .libc_file = if (target.result.os.tag.isDarwin()) libc_file: {
                switch (try apple_sdk.pathsForTarget(b, target.result)) {
                    inline else => |paths| break :libc_file paths.libc,
                }
            } else null,
        });

        // Blocks need to be enabled to use MacOS headers
        macos_c.run.addArg("-fblocks");

        module.addImport("macos_c", macos_c.mod);
    }

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
