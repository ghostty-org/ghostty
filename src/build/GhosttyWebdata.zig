//! GhosttyWebdata generates all the Ghostty website data that is
//! merged with the website for things like config references.
const GhosttyWebdata = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

steps: []*std.Build.Step,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyWebdata {
    var steps = std.ArrayList(*std.Build.Step).init(b.allocator);
    errdefer steps.deinit();

    {
        const webgen_config = b.addExecutable(.{
            .name = "webgen_config",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.graph.host,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
        });
        deps.help_strings.addImport(webgen_config);

        {
            const buildconfig = config: {
                var copy = deps.config.*;
                copy.exe_entrypoint = .webgen_config;
                break :config copy;
            };

            const options = b.addOptions();
            try buildconfig.addOptions(options);
            webgen_config.root_module.addOptions("build_options", options);
        }

        const webgen_config_step = b.addRunArtifact(webgen_config);
        const webgen_config_out = webgen_config_step.captureStdOut();

        try steps.append(&b.addInstallFile(
            webgen_config_out,
            "share/ghostty/webdata/config.mdx",
        ).step);
    }

    {
        const webgen_actions = b.addExecutable(.{
            .name = "webgen_actions",
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        });
        deps.help_strings.addImport(webgen_actions);

        {
            const buildconfig = config: {
                var copy = deps.config.*;
                copy.exe_entrypoint = .webgen_actions;
                break :config copy;
            };

            const options = b.addOptions();
            try buildconfig.addOptions(options);
            webgen_actions.root_module.addOptions("build_options", options);
        }

        const webgen_actions_step = b.addRunArtifact(webgen_actions);
        const webgen_actions_out = webgen_actions_step.captureStdOut();

        try steps.append(&b.addInstallFile(
            webgen_actions_out,
            "share/ghostty/webdata/actions.mdx",
        ).step);
    }

    {
        const webgen_commands = b.addExecutable(.{
            .name = "webgen_commands",
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        });
        deps.help_strings.addImport(webgen_commands);

        {
            const buildconfig = config: {
                var copy = deps.config.*;
                copy.exe_entrypoint = .webgen_commands;
                break :config copy;
            };

            const options = b.addOptions();
            try buildconfig.addOptions(options);
            webgen_commands.root_module.addOptions("build_options", options);
        }

        const webgen_commands_step = b.addRunArtifact(webgen_commands);
        const webgen_commands_out = webgen_commands_step.captureStdOut();

        try steps.append(&b.addInstallFile(
            webgen_commands_out,
            "share/ghostty/webdata/commands.mdx",
        ).step);
    }

    return .{ .steps = steps.items };
}

pub fn install(self: *const GhosttyWebdata) void {
    const b = self.steps[0].owner;
    for (self.steps) |step| b.getInstallStep().dependOn(step);
}
