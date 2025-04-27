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
    // Get the resources we're going to inject into the source tarball.
    const alloc = b.allocator;
    var resources: std.ArrayListUnmanaged(Resource) = .empty;
    {
        const gtk = SharedDeps.gtkDistResources(b);
        try resources.append(alloc, gtk.resources_c);
        try resources.append(alloc, gtk.resources_h);
    }

    // git archive to create the final tarball. "git archive" is the
    // easiest way I can find to create a tarball that ignores stuff
    // from gitignore and also supports adding files as well as removing
    // dist-only files (the "export-ignore" git attribute).
    const git_archive = b.addSystemCommand(&.{
        "git",
        "archive",
        "--format=tgz",
    });

    // embed the Ghostty version in the tarball
    {
        const version = b.addWriteFiles().add("VERSION", b.fmt("{}", .{cfg.version}));
        // --add-file uses the most recent --prefix to determine the path
        // in the archive to copy the file (the directory only).
        git_archive.addArg(b.fmt("--prefix=ghostty-{}/", .{
            cfg.version,
        }));
        git_archive.addPrefixedFileArg("--add-file=", version);
    }

    // Add all of our resources into the tarball.
    for (resources.items) |resource| {
        // Our dist path basename may not match our generated file basename,
        // and git archive requires this. To be safe, we copy the file once
        // to ensure the basename matches and then use that as the final
        // generated file.
        const copied = b.addWriteFiles().addCopyFile(
            resource.generated,
            std.fs.path.basename(resource.dist),
        );

        // --add-file uses the most recent --prefix to determine the path
        // in the archive to copy the file (the directory only).
        git_archive.addArg(b.fmt("--prefix=ghostty-{}/{s}/", .{
            cfg.version,
            std.fs.path.dirname(resource.dist).?,
        }));
        git_archive.addPrefixedFileArg("--add-file=", copied);
    }

    // Add our output
    git_archive.addArgs(&.{
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

    // Check that all our dist resources are at the proper path.
    for (resources.items) |resource| {
        const path = extract_dir.path(b, resource.dist);
        const check_path = b.addCheckFile(path, .{});
        check_test.step.dependOn(&check_path.step);
    }

    return .{
        .archive = output,
        .install_step = &install.step,
        .archive_step = &git_archive.step,
        .check_step = &check_test.step,
    };
}

/// A dist resource is a resource that is built and distributed as part
/// of the source tarball with Ghostty. These aren't committed to the Git
/// repository but are built as part of the `zig build dist` command.
/// The purpose is to limit the number of build-time dependencies required
/// for downstream users and packagers.
pub const Resource = struct {
    /// The relative path in the source tree where the resource will be
    /// if it was pre-built. These are not checksummed or anything because the
    /// assumption is that the source tarball itself is checksummed and signed.
    dist: []const u8,

    /// The path to the generated resource in the build system. By depending
    /// on this you'll force it to regenerate. This does NOT point to the
    /// "path" above.
    generated: std.Build.LazyPath,

    /// Returns the path to use for this resource.
    pub fn path(self: *const Resource, b: *std.Build) std.Build.LazyPath {
        // If the dist path exists at build compile time then we use it.
        if (self.exists(b)) {
            return b.path(self.dist);
        }

        // Otherwise we use the generated path.
        return self.generated;
    }

    /// Returns true if the dist path exists at build time.
    pub fn exists(self: *const Resource, b: *std.Build) bool {
        if (std.fs.accessAbsolute(b.pathFromRoot(self.dist), .{})) {
            // If we have a ".git" directory then we're a git checkout
            // and we never want to use the dist path. This shouldn't happen
            // so show a warning to the user.
            if (std.fs.accessAbsolute(b.pathFromRoot(".git"), .{})) {
                std.log.warn(
                    "dist resource '{s}' should not be in a git checkout",
                    .{self.dist},
                );
                return false;
            } else |_| {}

            return true;
        } else |_| {
            return false;
        }
    }
};
