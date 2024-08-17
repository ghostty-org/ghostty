const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Config;

pub fn getEditor(alloc: std.mem.Allocator, config: *const Config) ![]const u8 {
    // figure out what our editor is
    if (config.editor) |editor| return try alloc.dupe(u8, editor);
    switch (builtin.os.tag) {
        .windows => {
            if (std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("EDITOR"))) |win_editor| {
                return try std.unicode.utf16leToUtf8Alloc(alloc, win_editor);
            }
        },
        else => if (std.posix.getenv("EDITOR")) |editor| return alloc.dupe(u8, editor),
    }
    return alloc.dupe(u8, "vi");
}
