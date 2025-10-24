//! This CLI is used to generate data that is used by the build process.
//!
//! We used to do this directly in our `build.zig` but the problem with
//! that approach is that any changes to the dependencies of this data would
//! force a rebuild of our build binary. If we're just doing something like
//! running tests and not emitting any of the info below, then that is a
//! complete waste.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");

pub const Action = enum {
    // Shell completions
    bash,
    fish,
    zsh,

    // Editor syntax files
    sublime,
    @"vim-syntax",
    @"vim-ftdetect",
    @"vim-ftplugin",
    @"vim-compiler",

    // Other
    terminfo,
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const action_ = try cli.action.detectArgs(Action, alloc);
    const action = action_ orelse return error.NoAction;

    // Our output always goes to stdout.
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout_writer.interface;
    switch (action) {
        .bash => try writer.writeAll(@import("extra/bash.zig").completions),
        .fish => try writer.writeAll(@import("extra/fish.zig").completions),
        .zsh => try writer.writeAll(@import("extra/zsh.zig").completions),
        .sublime => try writer.writeAll(@import("extra/sublime.zig").syntax),
        .@"vim-syntax" => try writer.writeAll(@import("extra/vim.zig").syntax),
        .@"vim-ftdetect" => try writer.writeAll(@import("extra/vim.zig").ftdetect),
        .@"vim-ftplugin" => try writer.writeAll(@import("extra/vim.zig").ftplugin),
        .@"vim-compiler" => try writer.writeAll(@import("extra/vim.zig").compiler),
        .terminfo => try @import("terminfo/ghostty.zig").ghostty.encode(writer),
    }
    try stdout_writer.end();
}
