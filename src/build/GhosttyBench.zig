//! GhosttyBench generates all the Ghostty benchmark helper binaries.
const GhosttyBench = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

steps: []*std.Build.Step.Compile,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyBench {
    var steps = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    errdefer steps.deinit();

    // Open the directory ./src/bench
    const c_dir_path = b.pathFromRoot("src/bench");
    var c_dir = try std.fs.cwd().openDir(c_dir_path, .{ .iterate = true });
    defer c_dir.close();

    // Go through and add each as a step
    var c_dir_it = c_dir.iterate();
    while (try c_dir_it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (index == 0) continue;

        // If it doesn't end in 'zig' then ignore
        if (!std.mem.eql(u8, entry.name[index + 1 ..], "zig")) continue;

        // Name of the conformance app and full path to the entrypoint.
        const name = entry.name[0..index];

        // Executable builder.
        const bin_name = try std.fmt.allocPrint(b.allocator, "bench-{s}", .{name});
        const c_exe = b.addExecutable(.{
            .name = bin_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = deps.config.target,

                // We always want our benchmarks to be in release mode.
                .optimize = .ReleaseFast,
            }),
        });
        c_exe.linkLibC();

        // Update our entrypoint
        var enum_name: [64]u8 = undefined;
        @memcpy(enum_name[0..name.len], name);
        std.mem.replaceScalar(u8, enum_name[0..name.len], '-', '_');

        var buf: [64]u8 = undefined;
        const new_deps = try deps.changeEntrypoint(b, std.meta.stringToEnum(
            Config.ExeEntrypoint,
            try std.fmt.bufPrint(&buf, "bench_{s}", .{enum_name[0..name.len]}),
        ).?);

        _ = try new_deps.add(c_exe);

        try steps.append(c_exe);
    }

    return .{ .steps = steps.items };
}

pub fn install(self: *const GhosttyBench) void {
    const b = self.steps[0].step.owner;
    for (self.steps) |step| b.installArtifact(step);
}
