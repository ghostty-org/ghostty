//! GhosttyTerminfo builds terminfo source artifacts from Ghostty's Zig terminfo definition.
const GhosttyTerminfo = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const RunStep = std.Build.Step.Run;

terminfo_source: std.Build.LazyPath,
termcap_source: ?std.Build.LazyPath,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyTerminfo {
    const build_data_exe = b.addExecutable(.{
        .name = "ghostty-build-data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_build_data.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });
    build_data_exe.linkLibC();
    deps.help_strings.addImport(build_data_exe);

    const run = b.addRunArtifact(build_data_exe);
    run.addArg("+terminfo");
    const wf = b.addWriteFiles();
    const terminfo_source = wf.addCopyFile(run.captureStdOut(), "ghostty.terminfo");

    var termcap_source: ?std.Build.LazyPath = null;
    if (b.graph.host.result.os.tag != .windows) {
        const run_step = RunStep.create(b, "infotocap");
        run_step.addArg("infotocap");
        run_step.addFileArg(terminfo_source);
        termcap_source = run_step.captureStdOut();
        _ = run_step.captureStdErr(); // suppress noise
    }

    return .{
        .terminfo_source = terminfo_source,
        .termcap_source = termcap_source,
    };
}

pub fn installTerminfoSource(
    self: *const GhosttyTerminfo,
    b: *std.Build,
    cfg: *const Config,
) *std.Build.Step {
    const os_tag = cfg.target.result.os.tag;
    const dest = switch (os_tag) {
        .freebsd => "share/site-terminfo/ghostty.terminfo",
        else => "share/terminfo/ghostty.terminfo",
    };
    const source_install = b.addInstallFile(self.terminfo_source, dest);
    return &source_install.step;
}

pub fn installTermcapSource(
    self: *const GhosttyTerminfo,
    b: *std.Build,
    cfg: *const Config,
) ?*std.Build.Step {
    const os_tag = cfg.target.result.os.tag;
    const dest = switch (os_tag) {
        .freebsd => "share/site-terminfo/ghostty.termcap",
        else => "share/terminfo/ghostty.termcap",
    };
    if (self.termcap_source) |source| {
        const cap_install = b.addInstallFile(source, dest);
        return &cap_install.step;
    }
    return null;
}

/// Compiles and installs a terminfo database under share/terminfo (or
/// share/site-terminfo on FreeBSD), preserving symlinks in the output.
pub fn installCompiled(
    self: *const GhosttyTerminfo,
    b: *std.Build,
    cfg: *const Config,
    steps: *std.ArrayList(*std.Build.Step),
) !void {
    const os_tag = cfg.target.result.os.tag;

    const terminfo_share_dir = switch (os_tag) {
        .windows => return, // we don't support terminfo on Windows
        .freebsd => "site-terminfo",
        else => "terminfo",
    };

    const run_step = RunStep.create(b, "tic");
    run_step.addArgs(&.{ "tic", "-x", "-o" });
    const path = run_step.addOutputFileArg(terminfo_share_dir);
    run_step.addFileArg(self.terminfo_source);
    _ = run_step.captureStdErr(); // so we don't see stderr

    // Ensure that `share/terminfo` is a directory, otherwise `cp -R`
    // may create a file named `share/terminfo`.
    const mkdir_step = RunStep.create(b, "make share/terminfo directory");
    mkdir_step.addArgs(&.{ "mkdir", "-p" });
    mkdir_step.addArg(b.fmt(
        "{s}/share/{s}",
        .{ b.install_path, terminfo_share_dir },
    ));
    try steps.append(b.allocator, &mkdir_step.step);

    // Use cp -R because InstallDir doesn't preserve symlinks for this tree.
    const copy_step = RunStep.create(b, "copy terminfo db");
    copy_step.addArgs(&.{ "cp", "-R" });
    copy_step.addFileArg(path);
    copy_step.addArg(b.fmt("{s}/share", .{b.install_path}));
    copy_step.step.dependOn(&mkdir_step.step);
    try steps.append(b.allocator, &copy_step.step);
}
