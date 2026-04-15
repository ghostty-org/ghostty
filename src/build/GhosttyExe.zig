const Ghostty = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The primary winghostty executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "winghostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.strip,
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    // Set PIE if requested
    if (cfg.pie) exe.pie = true;

    // Add the shared dependencies. When building only lib-vt we skip
    // heavy deps so cross-compilation doesn't pull in GTK, etc.
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    // Windows-only fork: app builds no longer carry Nix/Linux-specific
    // launch guidance or rpath mutation behavior.
    try checkNixShell(exe, cfg);

    // Patch our rpath if that option is specified.
    if (cfg.patch_rpath) |rpath| {
        if (rpath.len > 0) {
            const run = std.Build.Step.Run.create(b, "patchelf rpath");
            run.addArgs(&.{ "patchelf", "--set-rpath", rpath });
            run.addArtifactArg(exe);
            install_step.step.dependOn(&run.step);
        }
    }

    // OS-specific
    switch (cfg.target.result.os.tag) {
        .windows => {
            exe.subsystem = .Windows;
            exe.addWin32ResourceFile(.{
                .file = b.path("dist/windows/winghostty.rc"),
            });
        },

        else => {},
    }

    return .{
        .exe = exe,
        .install_step = install_step,
    };
}

/// Add the winghostty exe to the install target.
pub fn install(self: *const Ghostty) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}

fn checkNixShell(exe: *std.Build.Step.Compile, cfg: *const Config) !void {
    _ = exe;
    _ = cfg;
}
