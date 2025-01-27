/// Wrapper around GTK's builder APIs that perform some comptime checks.
const Builder = @This();

const std = @import("std");
const c = @import("c.zig").c;

builder: *c.GtkBuilder,

pub fn init(comptime name: []const u8) Builder {
    comptime {
        // Use @embedFile to make sure that the file exists at compile
        // time. Zig _should_ discard the data so that it doesn't end up
        // in the final executable. At runtime we will load the data from
        // a GResource.
        _ = @embedFile("ui/" ++ name ++ ".ui");

        // Check to make sure that our file is listed as a `ui_file` in
        // `gresource.zig`. If it isn't Ghostty could crash at runtime
        // when we try and load a nonexistent GResource.
        const gresource = @import("gresource.zig");
        for (gresource.ui_files) |ui_file| {
            if (std.mem.eql(u8, ui_file, name)) break;
        } else @compileError("missing '" ++ name ++ "' in gresource.zig");
    }

    return .{
        .builder = c.gtk_builder_new_from_resource("/com/mitchellh/ghostty/ui/" ++ name ++ ".ui") orelse unreachable,
    };
}

pub fn getObject(self: *const Builder, comptime T: type, name: [:0]const u8) *T {
    return @ptrCast(@alignCast(c.gtk_builder_get_object(self.builder, name.ptr)));
}

pub fn deinit(self: *const Builder) void {
    c.g_object_unref(self.builder);
}
