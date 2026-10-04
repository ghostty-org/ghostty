//! Generate pkg-config files.
const GhosttyPkgConfig = @This();

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;

owner: *Build,
generator: *Step.Compile,
options: *Step.Options,

pub const Options = struct {
    name: []const u8,
    name_static: ?[]const u8 = null,
    description: []const u8,
    description_static: ?[]const u8 = null,

    version: std.SemanticVersion,
    libs: []const []const u8 = &.{},
    libs_static: ?[]const []const u8 = null,
    libs_private: []const []const u8 = &.{},
    reqs_private: []const []const u8 = &.{},
};

pub fn init(b: *Build, opts: Options) !GhosttyPkgConfig {
    const generator = b.addExecutable(.{
        .name = "pkg-config-generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/extra/pkg-config.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const libs = try std.mem.concat(b.allocator, u8, opts.libs);
    const libs_static = if (opts.libs_static) |s| try std.mem.concat(b.allocator, u8, s) else libs;

    const options = b.addOptions();
    options.addOption([]const u8, "name", opts.name);
    options.addOption([]const u8, "name_static", opts.name_static orelse opts.name);
    options.addOption([]const u8, "description", opts.description);
    options.addOption([]const u8, "description_static", opts.description_static orelse opts.description);
    options.addOption(std.SemanticVersion, "version", opts.version);
    options.addOption([]const u8, "libs", libs);
    options.addOption([]const u8, "libs_static", libs_static);
    options.addOption([]const u8, "libs_private", try std.mem.concat(b.allocator, u8, opts.libs_private));
    options.addOption([]const u8, "reqs_private", try std.mem.concat(b.allocator, u8, opts.reqs_private));
    generator.root_module.addOptions("options", options);

    return .{
        .owner = b,
        .generator = generator,
        .options = options,
    };
}

pub fn getSharedFile(self: *const GhosttyPkgConfig) LazyPath {
    const run = self.owner.addRunArtifact(self.generator);
    run.addDirectoryArg2(self.owner.graph.path(.install_prefix, ""), .{});
    return run.captureStdOut(.{});
}

pub fn getStaticFile(self: *const GhosttyPkgConfig) LazyPath {
    const run = self.owner.addRunArtifact(self.generator);
    run.setEnvironmentVariable("IS_STATIC", "1");
    run.addDirectoryArg2(self.owner.graph.path(.install_prefix, ""), .{});
    return run.captureStdOut(.{});
}
