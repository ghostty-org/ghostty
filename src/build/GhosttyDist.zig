const GhosttyDist = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyFrameData = @import("GhosttyFrameData.zig");

/// The final source tarball.
archive: std.Build.LazyPath,

/// The step to install the tarball.
install_step: *std.Build.Step,

/// The step to depend on
archive_step: *std.Build.Step,

/// The step to depend on for checking the dist
check_step: *std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyDist {
    // The name prefix used for all paths in the archive.
    const name = if (cfg.emit_lib_vt) "libghostty-vt" else "ghostty";

    // Get the resources we're going to inject into the source tarball.
    // lib-vt doesn't need GTK resources or frame data.
    const alloc = b.allocator;
    var resources: std.ArrayList(Resource) = .empty;
    if (!cfg.emit_lib_vt) {
        {
            const gtk = SharedDeps.gtkNgDistResources(b);
            try resources.append(alloc, gtk.resources_c);
            try resources.append(alloc, gtk.resources_h);
        }
        {
            const framedata = GhosttyFrameData.distResources(b);
            try resources.append(alloc, framedata.framedata);
        }
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
        const version = b.addWriteFiles().add("VERSION", b.fmt("{f}", .{cfg.version}));
        // --add-file uses the most recent --prefix to determine the path
        // in the archive to copy the file (the directory only).
        git_archive.addArg(b.fmt("--prefix={s}-{f}/", .{
            name, cfg.version,
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
            std.Io.Dir.path.basename(resource.dist),
        );

        // --add-file uses the most recent --prefix to determine the path
        // in the archive to copy the file (the directory only).
        git_archive.addArg(b.fmt("--prefix={s}-{f}/{s}/", .{
            name,                                 cfg.version,
            std.Io.Dir.path.dirname(resource.dist).?,
        }));
        git_archive.addPrefixedFileArg("--add-file=", copied);
    }

    // Add our output
    git_archive.addArgs(&.{
        // This is important. Standard source tarballs extract into
        // a directory named `project-version`. This is expected by
        // standard tooling such as debhelper and rpmbuild.
        b.fmt("--prefix={s}-{f}/", .{ name, cfg.version }),
        "-o",
    });
    const output = git_archive.addOutputFileArg(b.fmt(
        "{s}-{f}.tar.gz",
        .{ name, cfg.version },
    ));
    git_archive.addArg("HEAD");

    // When building for lib-vt only, exclude large directories that
    // are not needed to build libghostty-vt. This significantly reduces
    // the size of the resulting archive.
    if (cfg.emit_lib_vt) {
        for (lib_vt_excludes) |exclude| {
            git_archive.addArg(b.fmt(":(exclude){s}", .{exclude}));
        }
    }

    // The install step to put the dist into the build directory.
    const install = b.addInstallFile(
        output,
        b.fmt("dist/{s}-{f}.tar.gz", .{ name, cfg.version }),
    );

    // The check step to ensure the archive works.
    const check = b.addSystemCommand(&.{ "tar", "xvzf" });
    check.addFileArg(output);
    check.addArg("-C");

    // This is the root Ghostty source dir of the extracted source tarball.
    // i.e. this is way `build.zig` is.
    const extract_dir = check
        .addOutputDirectoryArg(name)
        .path(b, b.fmt("{s}-{f}", .{ name, cfg.version }));

    // Check that tests pass within the extracted directory. This isn't
    // a fully hermetic test because we're sharing the Zig cache. In
    // the future we could add an option to use a totally new cache but
    // in the interest of speed we don't do that for now and hope other
    // CI catches any issues.
    const check_test = step: {
        // For lib-vt, we run the lib-vt tests instead of the full test suite.
        const check_cmd = if (cfg.emit_lib_vt)
            &[_][]const u8{ "zig", "build", "test-lib-vt", "-Demit-lib-vt=true" }
        else
            &[_][]const u8{ "zig", "build", "test" };
        const step = b.addSystemCommand(check_cmd);
        step.setCwd(extract_dir);

        // Must be set so that Zig knows that this command doesn't
        // have side effects and is being run for its exit code check.
        // Zig will cache depending on its extract dir.
        step.expectExitCode(0);

        // Capture stderr so it doesn't spew into the parent build.
        // On the flip side, if the test fails we won't know why so
        // that sucks but we should have already ran tests at this point.
        // NOTE(mitchellh): temporarily disabled to diagnose heisenbug
        //_ = step.captureStdErr();

        break :step step;
    };

    // Check that all our dist resources are at the proper path.
    for (resources.items) |resource| {
        const path = extract_dir.path(b, resource.dist);
        const check_path = b.addCheckFile(path, .{});
        check_test.step.dependOn(&check_path.step);
    }

    // For lib-vt, also verify the CMake build works from the tarball.
    if (cfg.emit_lib_vt) {
        const cmake_build_dir = extract_dir.path(b, "cmake-build");
        const cmake_configure = b.addSystemCommand(&.{ "cmake", "-B" });
        cmake_configure.addDirectoryArg(cmake_build_dir);
        cmake_configure.setCwd(extract_dir);
        cmake_configure.expectExitCode(0);
        cmake_configure.step.dependOn(&check.step);

        const cmake_build = b.addSystemCommand(&.{ "cmake", "--build" });
        cmake_build.addDirectoryArg(cmake_build_dir);
        cmake_build.expectExitCode(0);
        cmake_build.step.dependOn(&cmake_configure.step);

        check_test.step.dependOn(&cmake_build.step);
    }

    return .{
        .archive = output,
        .install_step = &install.step,
        .archive_step = &git_archive.step,
        .check_step = &check_test.step,
    };
}

/// Paths to exclude from the dist archive when building for lib-vt only.
/// These are large files and directories that are not needed to build or
/// test libghostty-vt, specified as git pathspec exclude patterns.
const lib_vt_excludes = &[_][]const u8{
    // App and platform resources
    "images",
    "macos",
    "dist/doxygen",
    "dist/linux",
    "dist/macos",
    "dist/windows",
    "flatpak",
    "snap",
    "po",
    "example",

    // Test corpus (lib-vt tests use embedded testdata within src/terminal/)
    "test",

    // Large binary assets
    "src/font/res",
    "src/crash/testdata",
    "pkg/wuffs/src/too_big.jpg",
    "pkg/wuffs/src/too_big.png",
    "pkg/breakpad/vendor",

    // Vendored libraries not used by lib-vt
    "vendor",
};

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
        if (b.build_root.handle.access(b.graph.io, self.dist, .{})) {
            // If we have a ".git" directory then we're a git checkout
            // and we never want to use the dist path. This shouldn't happen
            // so show a warning to the user.
            if (b.build_root.handle.access(b.graph.io, ".git", .{})) {
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
