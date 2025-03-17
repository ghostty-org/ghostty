/// Wrapper around GTK's builder APIs that perform some comptime checks.
const Builder = @This();

const std = @import("std");

const gtk = @import("gtk");
const gobject = @import("gobject");

resource_name: [:0]const u8,
builder: ?*gtk.Builder,

pub fn init(
    /// The "name" of the resource.
    comptime name: []const u8,
    /// The major version of the minimum Adwaita version that is required to use
    /// this resource.
    comptime major: u16,
    /// The minor version of the minimum Adwaita version that is required to use
    /// this resource.
    comptime minor: u16,
) Builder {
    const resource_path = comptime resource_path: {
        const gresource = @import("gresource.zig");
        // Check to make sure that our file is listed as a
        // `blueprint_file` in `gresource.zig`. If it isn't Ghostty
        // could crash at runtime when we try and load a nonexistent
        // GResource.
        for (gresource.blueprint_files) |file| {
            if (major != file.major or minor != file.minor or !std.mem.eql(u8, file.name, name)) continue;
            // Use @embedFile to make sure that the `.blp` file exists
            // at compile time. Zig _should_ discard the data so that
            // it doesn't end up in the final executable. At runtime we
            // will load the data from a GResource.
            const blp_filename = std.fmt.comptimePrint(
                "ui/{d}.{d}/{s}.blp",
                .{
                    file.major,
                    file.minor,
                    file.name,
                },
            );
            _ = @embedFile(blp_filename);
            break :resource_path std.fmt.comptimePrint(
                "/com/mitchellh/ghostty/ui/{d}.{d}/{s}.ui",
                .{
                    file.major,
                    file.minor,
                    file.name,
                },
            );
        } else @compileError("missing blueprint file '" ++ name ++ "' in gresource.zig");
    };

    return .{
        .resource_name = resource_path,
        .builder = null,
    };
}

pub fn setWidgetClassTemplate(self: *const Builder, class: *gtk.WidgetClass) void {
    class.setTemplateFromResource(self.resource_name);
}

pub fn getObject(self: *Builder, comptime T: type, name: [:0]const u8) ?*T {
    const builder = builder: {
        if (self.builder) |builder| break :builder builder;
        const builder = gtk.Builder.newFromResource(self.resource_name);
        self.builder = builder;
        break :builder builder;
    };

    return gobject.ext.cast(T, builder.getObject(name) orelse return null);
}

pub fn deinit(self: *const Builder) void {
    if (self.builder) |builder| builder.unref();
}
