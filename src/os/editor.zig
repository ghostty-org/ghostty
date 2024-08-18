const std = @import("std");
const builtin = @import("builtin");

pub fn getEditor(alloc: std.mem.Allocator, editor: ?[]const u8) ![]const u8 {
    // figure out what our editor is
    if (editor) |e| return try alloc.dupe(u8, e);
    switch (builtin.os.tag) {
        .windows => {
            if (std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("EDITOR"))) |win_editor| {
                return try std.unicode.utf16leToUtf8Alloc(alloc, win_editor);
            }
        },
        else => if (std.posix.getenv("EDITOR")) |e| return alloc.dupe(u8, e),
    }
    return alloc.dupe(u8, "vi");
}
