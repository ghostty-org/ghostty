const std = @import("std");
const help_strings = @import("help_strings");
const KeybindAction = @import("../../input/Binding.zig").Action;

pub fn main() !void {
    const output = std.io.getStdOut().writer();
    try genKeybindActions(output);
}

pub fn genKeybindActions(writer: anytype) !void {
    // Write the header
    try writer.writeAll(
        \\---
        \\title: Keybinding Action Reference
        \\description: Reference of all Ghostty keybinding actions.
        \\editOnGithubLink: https://github.com/ghostty-org/ghostty/edit/main/src/input/Binding.zig
        \\---
        \\
        \\This is a reference of all Ghostty keybinding actions.
        \\
        \\
    );

    @setEvalBranchQuota(5_000);

    var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buffer.deinit();

    const fields = @typeInfo(KeybindAction).Union.fields;
    inline for (fields) |field| {
        if (field.name[0] == '_') continue;

        // Write previously stored doc comment below all related actions
        if (@hasDecl(help_strings.KeybindAction, field.name)) {
            try writer.writeAll(buffer.items);
            try writer.writeAll("\n");

            buffer.clearRetainingCapacity();
        }

        // Write the field name.
        try writer.writeAll("## `");
        try writer.writeAll(field.name);
        try writer.writeAll("`\n");

        if (@hasDecl(help_strings.KeybindAction, field.name)) {
            var iter = std.mem.splitScalar(
                u8,
                @field(help_strings.KeybindAction, field.name),
                '\n',
            );
            while (iter.next()) |s| {
                try buffer.appendSlice(s);
                try buffer.appendSlice("\n");
            }
        }
    }
}
