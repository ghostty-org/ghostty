const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub const FontAtlas = opaque {
    pub fn addFontFromMemoryTTF(
        self: *FontAtlas,
        data: []const u8,
        size_px: f32,
    ) void {
        // We never want the data to be copied by the Atlas, its not
        // very Zig-like, so we just always set this to false.
        var cfg = c.ImFontConfig_ImFontConfig();
        cfg.*.FontDataOwnedByAtlas = false;
        defer c.ImFontConfig_destroy(cfg);

        _ = c.ImFontAtlas_AddFontFromMemoryTTF(
            self.cval(),
            @ptrFromInt(@intFromPtr(data.ptr)),
            @intCast(data.len),
            size_px,
            cfg,
            null,
        );
    }

    pub inline fn cval(self: *FontAtlas) *c.ImFontAtlas {
        return @ptrCast(@alignCast(self));
    }
};
