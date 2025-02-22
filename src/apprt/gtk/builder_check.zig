const std = @import("std");
const build_options = @import("build_options");

const gtk = @import("gtk");
const adw = @import("adw");

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

    const data = try std.fs.cwd().readFileAllocOptions(alloc, filename, std.math.maxInt(u16), null, 1, 0);
    defer alloc.free(data);

    if (gtk.initCheck() == 0) {
        std.debug.print("{s}: skipping builder check because we can't connect to display!\n", .{filename});
        return;
    }

    adw.init();

    const builder = gtk.Builder.newFromString(data.ptr, @intCast(data.len));
    defer builder.unref();
}
