const GhosttyResources = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const buildpkg = @import("main.zig");
const Config = @import("Config.zig");
const config_vim = @import("../config/vim.zig");
const config_sublime_syntax = @import("../config/sublime_syntax.zig");
const terminfo = @import("../terminfo/main.zig");
const RunStep = std.Build.Step.Run;

steps: []*std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyResources {
    var steps = std.ArrayList(*std.Build.Step).init(b.allocator);
    errdefer steps.deinit();

    // Terminfo
    terminfo: {
        const os_tag = cfg.target.result.os.tag;
        const terminfo_share_dir = if (os_tag == .freebsd)
            "site-terminfo"
        else
            "terminfo";

        // Encode our terminfo
        var str = std.ArrayList(u8).init(b.allocator);
        defer str.deinit();
        try terminfo.ghostty.encode(str.writer());

        // Write it
        var wf = b.addWriteFiles();
        const source = wf.add("ghostty.terminfo", str.items);

        if (cfg.emit_terminfo) {
            const source_install = b.addInstallFile(
                source,
                if (os_tag == .freebsd)
                    "share/site-terminfo/ghostty.terminfo"
                else
                    "share/terminfo/ghostty.terminfo",
            );

            try steps.append(&source_install.step);
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

            try steps.append(&cap_install.step);
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

            try steps.append(&mkdir_step.step);

            // Use cp -R instead of Step.InstallDir because we need to preserve
            // symlinks in the terminfo database. Zig's InstallDir step doesn't
            // handle symlinks correctly yet.
            const copy_step = RunStep.create(b, "copy terminfo db");
            copy_step.addArgs(&.{ "cp", "-R" });
            copy_step.addFileArg(path);
            copy_step.addArg(b.fmt("{s}/share", .{b.install_path}));
            copy_step.step.dependOn(&mkdir_step.step);
            try steps.append(&copy_step.step);
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
        try steps.append(&install_step.step);
    }

    // Themes
    if (b.lazyDependency("iterm2_themes", .{})) |upstream| {
        const install_step = b.addInstallDirectory(.{
            .source_dir = upstream.path("ghostty"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ "ghostty", "themes" }),
            .exclude_extensions = &.{".md"},
        });
        try steps.append(&install_step.step);
    }

    // Fish shell completions
    {
        const wf = b.addWriteFiles();
        _ = wf.add("ghostty.fish", buildpkg.fish_completions);

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/fish/vendor_completions.d",
        });
        try steps.append(&install_step.step);
    }

    // zsh shell completions
    {
        const wf = b.addWriteFiles();
        _ = wf.add("_ghostty", buildpkg.zsh_completions);

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/zsh/site-functions",
        });
        try steps.append(&install_step.step);
    }

    // bash shell completions
    {
        const wf = b.addWriteFiles();
        _ = wf.add("ghostty.bash", buildpkg.bash_completions);

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bash-completion/completions",
        });
        try steps.append(&install_step.step);
    }

    // Vim plugin
    {
        const wf = b.addWriteFiles();
        _ = wf.add("syntax/ghostty.vim", config_vim.syntax);
        _ = wf.add("ftdetect/ghostty.vim", config_vim.ftdetect);
        _ = wf.add("ftplugin/ghostty.vim", config_vim.ftplugin);
        _ = wf.add("compiler/ghostty.vim", config_vim.compiler);

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/vim/vimfiles",
        });
        try steps.append(&install_step.step);
    }

    // Neovim plugin
    // This is just a copy-paste of the Vim plugin, but using a Neovim subdir.
    // By default, Neovim doesn't look inside share/vim/vimfiles. Some distros
    // configure it to do that however. Fedora, does not as a counterexample.
    {
        const wf = b.addWriteFiles();
        _ = wf.add("syntax/ghostty.vim", config_vim.syntax);
        _ = wf.add("ftdetect/ghostty.vim", config_vim.ftdetect);
        _ = wf.add("ftplugin/ghostty.vim", config_vim.ftplugin);
        _ = wf.add("compiler/ghostty.vim", config_vim.compiler);

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/nvim/site",
        });
        try steps.append(&install_step.step);
    }

    // Sublime syntax highlighting for bat cli tool
    // NOTE: The current implementation requires symlinking the generated
    // 'ghostty.sublime-syntax' file from zig-out to the '~.config/bat/syntaxes'
    // directory. The syntax then needs to be mapped to the correct language in
    // the config file within the '~.config/bat' directory
    // (ex: --map-syntax "/Users/user/.config/ghostty/config:Ghostty Config").
    {
        const wf = b.addWriteFiles();
        _ = wf.add("ghostty.sublime-syntax", config_sublime_syntax.syntax);

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bat/syntaxes",
        });
        try steps.append(&install_step.step);
    }

    // App (Linux)
    if (cfg.target.result.os.tag == .linux) try addLinuxAppResources(
        b,
        cfg,
        &steps,
    );

    return .{ .steps = steps.items };
}

/// Add the resource files needed to make Ghostty a proper
/// Linux desktop application (for various desktop environments).
fn addLinuxAppResources(
    b: *std.Build,
    cfg: *const Config,
    steps: *std.ArrayList(*std.Build.Step),
) !void {
    assert(cfg.target.result.os.tag == .linux);

    // Background:
    // https://developer.gnome.org/documentation/guidelines/maintainer/integrating.html

    const name = b.fmt("Ghostty{s}", .{
        switch (cfg.optimize) {
            .Debug, .ReleaseSafe => " (Debug)",
            .ReleaseFast, .ReleaseSmall => "",
        },
    });

    const app_id = b.fmt("com.mitchellh.ghostty{s}", .{
        switch (cfg.optimize) {
            .Debug, .ReleaseSafe => "-debug",
            .ReleaseFast, .ReleaseSmall => "",
        },
    });

    const exe_abs_path = b.fmt(
        "{s}/bin/ghostty",
        .{b.install_prefix},
    );

    // The templates that we will process. The templates are in
    // cmake format and will be processed and saved to the
    // second element of the tuple.
    const Template = struct { std.Build.LazyPath, []const u8 };
    const templates: []const Template = templates: {
        var ts: std.ArrayList(Template) = .init(b.allocator);

        // Desktop file so that we have an icon and other metadata
        try ts.append(.{
            b.path("dist/linux/app.desktop.in"),
            b.fmt("share/applications/{s}.desktop", .{app_id}),
        });

        // Service for DBus activation.
        try ts.append(.{
            if (cfg.flatpak)
                b.path("dist/linux/dbus.service.flatpak.in")
            else
                b.path("dist/linux/dbus.service.in"),
            b.fmt("share/dbus-1/services/{s}.service", .{app_id}),
        });

        // systemd user service. This is kind of nasty but systemd
        // looks for user services in different paths depending on
        // if we are installed as a system package or not (lib vs.
        // share) so we have to handle that here. We might be able
        // to get away with always installing to both because it
        // only ever searches in one... but I don't want to do that hack
        // until we have to.
        if (!cfg.flatpak) try ts.append(.{
            b.path("dist/linux/systemd.service.in"),
            b.fmt(
                "{s}/systemd/user/{s}.service",
                .{
                    if (b.graph.system_package_mode) "lib" else "share",
                    app_id,
                },
            ),
        });

        // AppStream metainfo so that application has rich metadata
        // within app stores
        try ts.append(.{
            b.path("dist/linux/com.mitchellh.ghostty.metainfo.xml.in"),
            b.fmt("share/metainfo/{s}.metainfo.xml", .{app_id}),
        });

        break :templates ts.items;
    };

    // Process all our templates
    for (templates) |template| {
        const tpl = b.addConfigHeader(.{
            .style = .{ .cmake = template[0] },
        }, .{
            .NAME = name,
            .APPID = app_id,
            .GHOSTTY = exe_abs_path,
        });

        // Template output has a single header line we want to remove.
        // We use `tail` to do it since its part of the POSIX standard.
        const tail = b.addSystemCommand(&.{ "tail", "-n", "+2" });
        tail.setStdIn(.{ .lazy_path = tpl.getOutput() });

        const copy = b.addInstallFile(
            tail.captureStdOut(),
            template[1],
        );

        try steps.append(&copy.step);
    }

    // Right click menu action for Plasma desktop
    try steps.append(&b.addInstallFile(
        b.path("dist/linux/ghostty_dolphin.desktop"),
        "share/kio/servicemenus/com.mitchellh.ghostty.desktop",
    ).step);

    // Right click menu action for Nautilus. Note that this _must_ be named
    // `ghostty.py`. Using the full app id causes problems (see #5468).
    try steps.append(&b.addInstallFile(
        b.path("dist/linux/ghostty_nautilus.py"),
        "share/nautilus-python/extensions/ghostty.py",
    ).step);

    // Various icons that our application can use, including the icon
    // that will be used for the desktop.
    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_16.png"),
        "share/icons/hicolor/16x16/apps/com.mitchellh.ghostty.png",
    ).step);
    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_32.png"),
        "share/icons/hicolor/32x32/apps/com.mitchellh.ghostty.png",
    ).step);
    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_128.png"),
        "share/icons/hicolor/128x128/apps/com.mitchellh.ghostty.png",
    ).step);
    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_256.png"),
        "share/icons/hicolor/256x256/apps/com.mitchellh.ghostty.png",
    ).step);
    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_512.png"),
        "share/icons/hicolor/512x512/apps/com.mitchellh.ghostty.png",
    ).step);
    // Flatpaks only support icons up to 512x512.
    if (!cfg.flatpak) {
        try steps.append(&b.addInstallFile(
            b.path("images/icons/icon_1024.png"),
            "share/icons/hicolor/1024x1024/apps/com.mitchellh.ghostty.png",
        ).step);
    }

    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_16@2x.png"),
        "share/icons/hicolor/16x16@2/apps/com.mitchellh.ghostty.png",
    ).step);
    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_32@2x.png"),
        "share/icons/hicolor/32x32@2/apps/com.mitchellh.ghostty.png",
    ).step);
    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_128@2x.png"),
        "share/icons/hicolor/128x128@2/apps/com.mitchellh.ghostty.png",
    ).step);
    try steps.append(&b.addInstallFile(
        b.path("images/icons/icon_256@2x.png"),
        "share/icons/hicolor/256x256@2/apps/com.mitchellh.ghostty.png",
    ).step);
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
