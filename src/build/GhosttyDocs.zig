//! GhosttyDocs generates all the on-disk documentation that Ghostty is
//! installed with (man pages, html, markdown, etc.)
const GhosttyDocs = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

steps: []*std.Build.Step,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyDocs {
    var steps = std.ArrayList(*std.Build.Step).init(b.allocator);
    errdefer steps.deinit();

    const manpages = [_]struct {
        name: []const u8,
        section: []const u8,
    }{
        .{ .name = "ghostty", .section = "1" },
        .{ .name = "ghostty", .section = "5" },
    };

    inline for (manpages) |manpage| {
        const generate_markdown = b.addExecutable(.{
            .name = "mdgen_" ++ manpage.name ++ "_" ++ manpage.section,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.graph.host,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
        });
        deps.help_strings.addImport(generate_markdown);

        const gen_config = config: {
            var copy = deps.config.*;
            copy.exe_entrypoint = @field(
                Config.ExeEntrypoint,
                "mdgen_" ++ manpage.name ++ "_" ++ manpage.section,
            );
            break :config copy;
        };

        const generate_markdown_options = b.addOptions();
        try gen_config.addOptions(generate_markdown_options);
        generate_markdown.root_module.addOptions("build_options", generate_markdown_options);

        const generate_markdown_step = b.addRunArtifact(generate_markdown);
        const markdown_output = generate_markdown_step.captureStdOut();

        try steps.append(&b.addInstallFile(
            markdown_output,
            "share/ghostty/doc/" ++ manpage.name ++ "." ++ manpage.section ++ ".md",
        ).step);

        const generate_html = b.addSystemCommand(&.{"pandoc"});
        generate_html.addArgs(&.{
            "--standalone",
            "--from",
            "markdown",
            "--to",
            "html",
        });
        generate_html.addFileArg(markdown_output);

        try steps.append(&b.addInstallFile(
            generate_html.captureStdOut(),
            "share/ghostty/doc/" ++ manpage.name ++ "." ++ manpage.section ++ ".html",
        ).step);

        const generate_manpage = b.addSystemCommand(&.{"pandoc"});
        generate_manpage.addArgs(&.{
            "--standalone",
            "--from",
            "markdown",
            "--to",
            "man",
        });
        generate_manpage.addFileArg(markdown_output);

        try steps.append(&b.addInstallFile(
            generate_manpage.captureStdOut(),
            "share/man/man" ++ manpage.section ++ "/" ++ manpage.name ++ "." ++ manpage.section,
        ).step);
    }

    return .{ .steps = steps.items };
}

pub fn install(self: *const GhosttyDocs) void {
    const b = self.steps[0].owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyDocs,
    other_step: *std.Build.Step,
) void {
    for (self.steps) |step| other_step.dependOn(step);
}

/// Installs some dummy files to satisfy the folder structure of docs
/// without actually generating any documentation. This is useful
/// when the `emit-docs` option is not set to true, but we still
/// need the rough directory structure to exist, such as for the macOS
/// app.
pub fn installDummy(self: *const GhosttyDocs, step: *std.Build.Step) void {
    _ = self;

    const b = step.owner;
    var wf = b.addWriteFiles();
    const path = "share/man/.placeholder";
    step.dependOn(&b.addInstallFile(
        wf.add(
            path,
            "emit-docs not true so no man pages",
        ),
        path,
    ).step);
}
