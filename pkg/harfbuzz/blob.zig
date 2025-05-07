const std = @import("std");
const c = @import("c.zig").c;
const Error = @import("errors.zig").Error;

/// Data type holding the memory modes available to client programs.
///
/// Regarding these various memory-modes:
///
///   - In no case shall the HarfBuzz client modify memory that is passed to
///     HarfBuzz in a blob. If there is any such possibility,
///     HB_MEMORY_MODE_DUPLICATE should be used such that HarfBuzz makes a
///     copy immediately,
///
///   - Use HB_MEMORY_MODE_READONLY otherwise, unless you really really really
///     know what you are doing,
///
///   - HB_MEMORY_MODE_WRITABLE is appropriate if you really made a copy of
///     data solely for the purpose of passing to HarfBuzz and doing that
///     just once (no reuse!),
///
///   - If the font is mmap()ed, it's okay to use
///     HB_MEMORY_READONLY_MAY_MAKE_WRITABLE , however, using that mode
///     correctly is very tricky. Use HB_MEMORY_MODE_READONLY instead.
pub const MemoryMode = enum(u2) {
    /// HarfBuzz immediately makes a copy of the data.
    duplicate = c.HB_MEMORY_MODE_DUPLICATE,

    /// HarfBuzz client will never modify the data, and HarfBuzz will never
    /// modify the data.
    readonly = c.HB_MEMORY_MODE_READONLY,

    /// HarfBuzz client made a copy of the data solely for HarfBuzz, so
    /// HarfBuzz may modify the data.
    writable = c.HB_MEMORY_MODE_WRITABLE,

    /// See above
    readonly_may_make_writable = c.HB_MEMORY_MODE_READONLY_MAY_MAKE_WRITABLE,
};

/// Blobs wrap a chunk of binary data to handle lifecycle management of data
/// while it is passed between client and HarfBuzz. Blobs are primarily
/// used to create font faces, but also to access font face tables, as well as
/// pass around other binary data.
pub const Blob = struct {
    handle: *c.hb_blob_t,

    /// Creates a new "blob" object wrapping data . The mode parameter is used
    /// to negotiate ownership and lifecycle of data .
    ///
    /// Note that this function returns a freshly-allocated empty blob even
    /// if length is zero. This is in contrast to hb_blob_create(), which
    /// returns the singleton empty blob (as returned by hb_blob_get_empty())
    /// if length is zero.
    pub fn create(data: []const u8, mode: MemoryMode) Error!Blob {
        const handle = c.hb_blob_create_or_fail(
            data.ptr,
            @intCast(data.len),
            @intFromEnum(mode),
            null,
            null,
        ) orelse return Error.HarfbuzzFailed;

        return Blob{ .handle = handle };
    }

    /// Decreases the reference count on blob , and if it reaches zero,
    /// destroys blob , freeing all memory, possibly calling the
    /// destroy-callback the blob was created for if it has not been
    /// called already.
    pub fn destroy(self: *Blob) void {
        c.hb_blob_destroy(self.handle);
    }

    /// Attaches a user-data key/data pair to the specified blob.
    pub fn setUserData(
        self: Blob,
        comptime T: type,
        key: ?*anyopaque,
        ptr: ?*T,
        comptime destroycb: ?*const fn (?*T) callconv(.c) void,
        replace: bool,
    ) bool {
        const Callback = struct {
            pub fn callback(data: ?*anyopaque) callconv(.c) void {
                @call(.{ .modifier = .always_inline }, destroycb, .{
                    @as(?*T, @ptrCast(@alignCast(data))),
                });
            }
        };

        return c.hb_blob_set_user_data(
            self.handle,
            @ptrCast(key),
            ptr,
            if (destroycb != null) Callback.callback else null,
            if (replace) 1 else 0,
        ) > 0;
    }

    /// Fetches the user data associated with the specified key, attached to
    /// the specified font-functions structure.
    pub fn getUserData(
        self: Blob,
        comptime T: type,
        key: ?*anyopaque,
    ) ?*T {
        const opt = c.hb_blob_get_user_data(self.handle, @ptrCast(key));
        if (opt) |ptr|
            return @ptrCast(@alignCast(ptr))
        else
            return null;
    }
};

test {
    const testing = std.testing;

    const data = "hello";
    var blob = try Blob.create(data, .readonly);
    defer blob.destroy();

    var userdata: u8 = 127;
    var key: u8 = 0;
    try testing.expect(blob.setUserData(u8, &key, &userdata, null, false));
    try testing.expect(blob.getUserData(u8, &key).?.* == 127);
}
