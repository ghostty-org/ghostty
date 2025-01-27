const std = @import("std");
const build_options = @import("build_options");

pub const c = @cImport({
    @cInclude("gtk/gtk.h");
    if (build_options.adwaita) {
        @cInclude("libadwaita-1/adwaita.h");
    }
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

    if (c.gtk_init_check() == 0) {
        std.debug.print("skipping builder check because we can't connect to display!\n", .{});
        return;
    }

    if (comptime build_options.adwaita) {
        c.adw_init();
    } else {
        if (std.mem.indexOf(u8, filename, "adw")) |_| return;
    }

    const builder = c.gtk_builder_new_from_file(filename.ptr);
    defer c.g_object_unref(builder);
}
