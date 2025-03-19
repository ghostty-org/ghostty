const GhosttyDist = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The final source tarball.
archive: std.Build.LazyPath,

/// The step to install the tarball.
install_step: *std.Build.Step,

/// The step to depend on
archive_step: *std.Build.Step,

/// The step to depend on for checking the dist
check_step: *std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyDist {
    // git archive to create the final tarball. "git archive" is the
    // easiest way I can find to create a tarball that ignores stuff
    // from gitignore and also supports adding files as well as removing
    // dist-only files (the "export-ignore" git attribute).
    const git_archive = b.addSystemCommand(&.{
        "git",
        "archive",
        "--format=tgz",

        // This is important. Standard source tarballs extract into
        // a directory named `project-version`. This is expected by
        // standard tooling such as debhelper and rpmbuild.
        b.fmt("--prefix=ghostty-{}/", .{cfg.version}),

        "-o",
    });
    const output = git_archive.addOutputFileArg(b.fmt(
        "ghostty-{}.tar.gz",
        .{cfg.version},
    ));
    git_archive.addArg("HEAD");

    // The install step to put the dist into the build directory.
    const install = b.addInstallFile(
        output,
        b.fmt("dist/ghostty-{}.tar.gz", .{cfg.version}),
    );

    // The check step to ensure the archive works.
    const check = b.addSystemCommand(&.{ "tar", "xvzf" });
    check.addFileArg(output);
    check.addArg("-C");

    // This is the root Ghostty source dir of the extracted source tarball.
    // i.e. this is way `build.zig` is.
    const extract_dir = check
        .addOutputDirectoryArg("ghostty")
        .path(b, b.fmt("ghostty-{}", .{cfg.version}));

    // Check that tests pass within the extracted directory. This isn't
    // a fully hermetic test because we're sharing the Zig cache. In
    // the future we could add an option to use a totally new cache but
    // in the interest of speed we don't do that for now and hope other
    // CI catches any issues.
    const check_test = step: {
        const step = b.addSystemCommand(&.{ "zig", "build", "test" });
        step.setCwd(extract_dir);

        // Must be set so that Zig knows that this command doesn't
        // have side effects and is being run for its exit code check.
        // Zig will cache depending on its extract dir.
        step.expectExitCode(0);

        // Capture stderr so it doesn't spew into the parent build.
        // On the flip side, if the test fails we won't know why so
        // that sucks but we should have already ran tests at this point.
        _ = step.captureStdErr();

        break :step step;
    };

    return .{
        .archive = output,
        .install_step = &install.step,
        .archive_step = &git_archive.step,
        .check_step = &check_test.step,
    };
}
