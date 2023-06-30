const Library = @This();

const std = @import("std");
const c = @import("c.zig");
const Face = @import("face.zig").Face;
const errors = @import("errors.zig");
const Error = errors.Error;
const intToError = errors.intToError;

handle: c.FT_Library,

/// Initialize a new FreeType library object. The set of modules that are
/// registered by this function is determined at build time.
pub fn init() Error!Library {
    var res = Library{ .handle = undefined };
    try intToError(c.FT_Init_FreeType(&res.handle));
    return res;
}

/// Destroy a given FreeType library object and all of its children,
/// including resources, drivers, faces, sizes, etc.
pub fn deinit(self: Library) void {
    _ = c.FT_Done_FreeType(self.handle);
}

/// Return the version of the FreeType library being used. This is useful when
/// dynamically linking to the library, since one cannot use the macros
/// FREETYPE_MAJOR, FREETYPE_MINOR, and FREETYPE_PATCH.
pub fn version(self: Library) Version {
    var v: Version = undefined;
    c.FT_Library_Version(self.handle, &v.major, &v.minor, &v.patch);
    return v;
}

/// Call FT_New_Face to open a font from a file.
pub fn initFace(self: Library, path: [:0]const u8, index: i32) Error!Face {
    var face: Face = undefined;
    try intToError(c.FT_New_Face(
        self.handle,
        path.ptr,
        index,
        &face.handle,
    ));
    return face;
}

/// Call FT_Open_Face to open a font that has been loaded into memory.
pub fn initMemoryFace(self: Library, data: []const u8, index: i32) Error!Face {
    var face: Face = undefined;
    try intToError(c.FT_New_Memory_Face(
        self.handle,
        data.ptr,
        @intCast(data.len),
        index,
        &face.handle,
    ));
    return face;
}

pub const Version = struct {
    major: i32,
    minor: i32,
    patch: i32,

    /// Convert the version to a string. The buffer should be able to
    /// accomodate the size, recommended to be at least 8 chars wide.
    /// The returned slice will be a slice of buf that contains the full
    /// version string.
    pub fn toString(self: Version, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{
            self.major, self.minor, self.patch,
        });
    }
};

test "basics" {
    const testing = std.testing;

    var lib = try init();
    defer lib.deinit();

    const vsn = lib.version();
    try testing.expect(vsn.major > 1);

    var buf: [32]u8 = undefined;
    _ = try vsn.toString(&buf);
}
