const Ghostty = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const Docs = @import("GhosttyDocs.zig");
const I18n = @import("GhosttyI18n.zig");
const Resources = @import("GhosttyResources.zig");
const XCFramework = @import("GhosttyXCFramework.zig");

build: *std.Build.Step.Run,
open: *std.Build.Step.Run,
copy: *std.Build.Step.Run,

pub const Deps = struct {
    xcframework: *const XCFramework,
    docs: *const Docs,
    i18n: *const I18n,
    resources: *const Resources,
};

pub fn init(
    b: *std.Build,
    config: *const Config,
    deps: Deps,
) !Ghostty {
    const xc_config = switch (config.optimize) {
        .Debug => "Debug",
        .ReleaseSafe,
        .ReleaseSmall,
        .ReleaseFast,
        => "Release",
    };

    const app_path = b.fmt("macos/build/{s}/Ghostty.app", .{xc_config});

    // Our step to build the Ghostty macOS app.
    const build = build: {
        // External environment variables can mess up xcodebuild, so
        // we create a new empty environment.
        const env_map = try b.allocator.create(std.process.EnvMap);
        env_map.* = .init(b.allocator);

        const build = RunStep.create(b, "xcodebuild");
        build.has_side_effects = true;
        build.cwd = b.path("macos");
        build.env_map = env_map;
        build.addArgs(&.{
            "xcodebuild",
            "-target",
            "Ghostty",
            "-configuration",
            xc_config,
        });

        switch (deps.xcframework.target) {
            // Universal is our default target, so we don't have to
            // add anything.
            .universal => {},

            // Native we need to override the architecture in the Xcode
            // project with the -arch flag.
            .native => build.addArgs(&.{
                "-arch",
                switch (builtin.cpu.arch) {
                    .aarch64 => "arm64",
                    .x86_64 => "x86_64",
                    else => @panic("unsupported macOS arch"),
                },
            }),
        }

        // We need the xcframework
        deps.xcframework.addStepDependencies(&build.step);

        // We also need all these resources because the xcode project
        // references them via symlinks.
        deps.resources.addStepDependencies(&build.step);
        deps.i18n.addStepDependencies(&build.step);
        deps.docs.installDummy(&build.step);

        // Expect success
        build.expectExitCode(0);

        break :build build;
    };

    // Our step to open the resulting Ghostty app.
    const open = open: {
        const disable_save_state = RunStep.create(b, "disable save state");
        disable_save_state.has_side_effects = true;
        disable_save_state.addArgs(&.{
            "/usr/libexec/PlistBuddy",
            "-c",
            // We'll have to change this to `Set` if we ever put this
            // into our Info.plist.
            "Add :NSQuitAlwaysKeepsWindows bool false",
            b.fmt("{s}/Contents/Info.plist", .{app_path}),
        });
        disable_save_state.expectExitCode(0);
        disable_save_state.step.dependOn(&build.step);

        const open = RunStep.create(b, "run Ghostty app");
        open.has_side_effects = true;
        open.cwd = b.path("");
        open.addArgs(&.{b.fmt(
            "{s}/Contents/MacOS/ghostty",
            .{app_path},
        )});

        // Open depends on the app
        open.step.dependOn(&build.step);
        open.step.dependOn(&disable_save_state.step);

        // This overrides our default behavior and forces logs to show
        // up on stderr (in addition to the centralized macOS log).
        open.setEnvironmentVariable("GHOSTTY_LOG", "1");

        // Configure how we're launching
        open.setEnvironmentVariable("GHOSTTY_MAC_LAUNCH_SOURCE", "zig_run");

        if (b.args) |args| {
            open.addArgs(args);
        }

        break :open open;
    };

    // Our step to copy the app bundle to the install path.
    // We have to use `cp -R` because there are symlinks in the
    // bundle.
    const copy = copy: {
        const step = RunStep.create(b, "copy app bundle");
        step.addArgs(&.{ "cp", "-R" });
        step.addFileArg(b.path(app_path));
        step.addArg(b.fmt("{s}", .{b.install_path}));
        step.step.dependOn(&build.step);
        break :copy step;
    };

    return .{
        .build = build,
        .open = open,
        .copy = copy,
    };
}

pub fn install(self: *const Ghostty) void {
    const b = self.copy.step.owner;
    b.getInstallStep().dependOn(&self.copy.step);
}

pub fn installXcframework(self: *const Ghostty) void {
    const b = self.build.step.owner;
    b.getInstallStep().dependOn(&self.build.step);
}
