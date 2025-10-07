const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const internal_os = @import("../../os/main.zig");
const glib = @import("glib");

pub fn resourcesDir(alloc: Allocator) !internal_os.ResourcesDir {
    if (comptime build_config.flatpak) {
        // Only consult Flatpak runtime data for host case.
        if (internal_os.isFlatpak()) {
            var result: internal_os.ResourcesDir = .{
                .app_path = try alloc.dupe(u8, "/app/share/ghostty"),
            };
            errdefer alloc.free(result.app_path.?);

            const keyfile = glib.KeyFile.new();
            defer keyfile.unref();

            if (keyfile.loadFromFile("/.flatpak-info", .{}, null) == 0) return result;
            const app_dir = std.mem.span(keyfile.getString("Instance", "app-path", null)) orelse return result;
            defer glib.free(app_dir.ptr);

            result.host_path = try std.fs.path.join(alloc, &[_][]const u8{ app_dir, "share", "ghostty" });
            return result;
        }
    }

    return try internal_os.resourcesDir(alloc);
}
