const GhosttyResources = @This();

const std = @import("std");
const Config = @import("Config.zig");
const RunStep = std.Build.Step.Run;
const SharedDeps = @import("SharedDeps.zig");

steps: []*std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !GhosttyResources {
    var steps: std.ArrayList(*std.Build.Step) = .empty;
    errdefer steps.deinit(b.allocator);

    // This is the exe used to generate some build data.
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

    // Terminfo
    terminfo: {
        const os_tag = cfg.target.result.os.tag;
        const terminfo_share_dir = if (os_tag == .freebsd)
            "site-terminfo"
        else
            "terminfo";

        // Encode our terminfo
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+terminfo");
        const wf = b.addWriteFiles();
        const source = wf.addCopyFile(run.captureStdOut(), "ghostty.terminfo");

        if (cfg.emit_terminfo) {
            const source_install = b.addInstallFile(
                source,
                if (os_tag == .freebsd)
                    "share/site-terminfo/ghostty.terminfo"
                else
                    "share/terminfo/ghostty.terminfo",
            );

            try steps.append(b.allocator, &source_install.step);
        }

        // Windows doesn't have the binaries below.
        if (os_tag == .windows) break :terminfo;

        // Convert to termcap source format if thats helpful to people and
        // install it. The resulting value here is the termcap source in case
        // that is used for other commands.
        if (cfg.emit_termcap) {
            const run_step = RunStep.create(b, "infotocap");
            run_step.addArg("infotocap");
            run_step.addFileArg(source);
            const out_source = run_step.captureStdOut();
            _ = run_step.captureStdErr(); // so we don't see stderr

            const cap_install = b.addInstallFile(
                out_source,
                if (os_tag == .freebsd)
                    "share/site-terminfo/ghostty.termcap"
                else
                    "share/terminfo/ghostty.termcap",
            );

            try steps.append(b.allocator, &cap_install.step);
        }

        // Compile the terminfo source into a terminfo database
        {
            const run_step = RunStep.create(b, "tic");
            run_step.addArgs(&.{ "tic", "-x", "-o" });
            const path = run_step.addOutputFileArg(terminfo_share_dir);

            run_step.addFileArg(source);
            _ = run_step.captureStdErr(); // so we don't see stderr

            // Ensure that `share/terminfo` is a directory, otherwise the `cp
            // -R` will create a file named `share/terminfo`
            const mkdir_step = RunStep.create(b, "make share/terminfo directory");
            switch (cfg.target.result.os.tag) {
                // windows mkdir shouldn't need "-p"
                .windows => mkdir_step.addArgs(&.{"mkdir"}),
                else => mkdir_step.addArgs(&.{ "mkdir", "-p" }),
            }

            mkdir_step.addArg(b.fmt(
                "{s}/share/{s}",
                .{ b.install_path, terminfo_share_dir },
            ));

            try steps.append(b.allocator, &mkdir_step.step);

            // Use cp -R instead of Step.InstallDir because we need to preserve
            // symlinks in the terminfo database. Zig's InstallDir step doesn't
            // handle symlinks correctly yet.
            const copy_step = RunStep.create(b, "copy terminfo db");
            copy_step.addArgs(&.{ "cp", "-R" });
            copy_step.addFileArg(path);
            copy_step.addArg(b.fmt("{s}/share", .{b.install_path}));
            copy_step.step.dependOn(&mkdir_step.step);
            try steps.append(b.allocator, &copy_step.step);
        }
    }

    // Shell-integration
    {
        const install_step = b.addInstallDirectory(.{
            .source_dir = b.path("src/shell-integration"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ "ghostty", "shell-integration" }),
            .exclude_extensions = &.{".md"},
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // Themes
    if (cfg.emit_themes) {
        if (b.lazyDependency("iterm2_themes", .{})) |upstream| {
            const install_step = b.addInstallDirectory(.{
                .source_dir = upstream.path(""),
                .install_dir = .{ .custom = "share" },
                .install_subdir = b.pathJoin(&.{ "ghostty", "themes" }),
                .exclude_extensions = &.{".md"},
            });
            try steps.append(b.allocator, &install_step.step);
        }
    }

    // Fish shell completions
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+fish");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(), "ghostty.fish");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/fish/vendor_completions.d",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // zsh shell completions
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+zsh");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(), "_ghostty");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/zsh/site-functions",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // bash shell completions
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+bash");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(), "ghostty.bash");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bash-completion/completions",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // Vim and Neovim plugin
    {
        const wf = b.addWriteFiles();

        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-syntax");
            _ = wf.addCopyFile(run.captureStdOut(), "syntax/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-ftdetect");
            _ = wf.addCopyFile(run.captureStdOut(), "ftdetect/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-ftplugin");
            _ = wf.addCopyFile(run.captureStdOut(), "ftplugin/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-compiler");
            _ = wf.addCopyFile(run.captureStdOut(), "compiler/ghostty.vim");
        }

        const vim_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/vim/vimfiles",
        });
        try steps.append(b.allocator, &vim_step.step);

        const neovim_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/nvim/site",
        });
        try steps.append(b.allocator, &neovim_step.step);
    }

    // Sublime syntax highlighting for bat cli tool
    // NOTE: The current implementation requires symlinking the generated
    // 'ghostty.sublime-syntax' file from zig-out to the '~.config/bat/syntaxes'
    // directory. The syntax then needs to be mapped to the correct language in
    // the config file within the '~.config/bat' directory
    // (ex: --map-syntax "/Users/user/.config/ghostty/config.ghostty:Ghostty Config").
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+sublime");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(), "ghostty.sublime-syntax");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bat/syntaxes",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // The Windows-only fork no longer installs Linux desktop integration
    // resources from the default app build.

    return .{ .steps = steps.items };
}

pub fn install(self: *const GhosttyResources) void {
    const b = self.steps[0].owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyResources,
    other_step: *std.Build.Step,
) void {
    for (self.steps) |step| other_step.dependOn(step);
}
