/// Wrapper around GTK's builder APIs that perform some comptime checks.
const Builder = @This();

const std = @import("std");

const gtk = @import("gtk");
const gobject = @import("gobject");

resource_name: [:0]const u8,
builder: ?*gtk.Builder,

pub fn init(comptime name: []const u8, comptime kind: enum { blp, ui }) Builder {
    comptime {
        switch (kind) {
            .blp => {
                // Use @embedFile to make sure that the file exists at compile
                // time. Zig _should_ discard the data so that it doesn't end
                // up in the final executable. At runtime we will load the data
                // from a GResource.
                _ = @embedFile("ui/" ++ name ++ ".blp");

                // Check to make sure that our file is listed as a
                // `blueprint_file` in `gresource.zig`. If it isn't Ghostty
                // could crash at runtime when we try and load a nonexistent
                // GResource.
                const gresource = @import("gresource.zig");
                for (gresource.blueprint_files) |blueprint_file| {
                    if (std.mem.eql(u8, blueprint_file, name)) break;
                } else @compileError("missing blueprint file '" ++ name ++ "' in gresource.zig");
            },
            .ui => {
                // Use @embedFile to make sure that the file exists at compile
                // time. Zig _should_ discard the data so that it doesn't end
                // up in the final executable. At runtime we will load the data
                // from a GResource.
                _ = @embedFile("ui/" ++ name ++ ".ui");

                // Check to make sure that our file is listed as a `ui_file` in
                // `gresource.zig`. If it isn't Ghostty could crash at runtime
                // when we try and load a nonexistent GResource.
                const gresource = @import("gresource.zig");
                for (gresource.ui_files) |ui_file| {
                    if (std.mem.eql(u8, ui_file, name)) break;
                } else @compileError("missing ui file '" ++ name ++ "' in gresource.zig");
            },
        }
    }

    return .{
        .resource_name = "/com/mitchellh/ghostty/ui/" ++ name ++ ".ui",
        .builder = null,
    };
}

pub fn setWidgetClassTemplate(self: *const Builder, class: *gtk.WidgetClass) void {
    class.setTemplateFromResource(self.resource_name);
}

pub fn getObject(self: *Builder, name: [:0]const u8) ?*gobject.Object {
    const builder = builder: {
        if (self.builder) |builder| break :builder builder;
        const builder = gtk.Builder.newFromResource(self.resource_name);
        self.builder = builder;
        break :builder builder;
    };

    return builder.getObject(name);
}

pub fn deinit(self: *const Builder) void {
    if (self.builder) |builder| builder.unref();
}
