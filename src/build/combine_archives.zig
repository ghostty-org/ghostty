//! Build tool that combines multiple static archives into a single fat
//! archive using an MRI script piped to `zig ar -M`.
//!
//! MRI scripts require stdin piping (`ar -M < script`), which can't be
//! expressed as a single command in the zig build system's RunStep. The
//! previous approach used `/bin/sh -c` to do the piping, but that isn't
//! available on Windows. This tool handles both the script generation
//! and the piping in a single cross-platform executable.
//!
//! Usage: combine_archives <zig_exe> <output.a> <input1.a> [input2.a ...]

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);

    if (args.len < 4) {
        std.log.err("usage: combine_archives <zig_exe> <output> <input...>", .{});
        std.process.exit(1);
    }

    const zig_exe = args[1];
    const output_path = args[2];
    const inputs = args[3..];

    // Build the MRI script.
    var script: std.Io.Writer.Allocating = .init(alloc);
    try script.writer.print("CREATE {s}\n", .{output_path});
    for (inputs) |input| {
        try script.writer.print("ADDLIB {s}\n", .{input});
    }
    try script.writer.writeAll("SAVE\nEND\n");

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ zig_exe, "ar", "-M" },
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    try child.stdin.?.writeStreamingAll(init.io, script.written());
    child.stdin.?.close(init.io);
    child.stdin = null;

    const term = try child.wait(init.io);
    if (term.exited != 0) {
        std.log.err("zig ar -M exited with code {d}", .{term.exited});
        std.process.exit(1);
    }
}
