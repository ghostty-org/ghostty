const std = @import("std");

pub const c = @cImport({
    @cInclude("gtk/gtk.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const filename = filename: {
        var it = try std.process.argsWithAllocator(alloc);
        defer it.deinit();

        _ = it.next() orelse return error.NoFilename;
        break :filename try alloc.dupeZ(u8, it.next() orelse return error.NoFilename);
    };
    defer alloc.free(filename);

    c.gtk_init();

    const builder = c.gtk_builder_new_from_file(filename.ptr);
    defer c.g_object_unref(builder);
}
