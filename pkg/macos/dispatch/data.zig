const std = @import("std");
const foundation = @import("../foundation.zig");
const c = @import("c");

pub const Data = opaque {
    pub const DESTRUCTOR_DEFAULT = c.DISPATCH_DATA_DESTRUCTOR_DEFAULT;

    pub fn create(
        data: []const u8,
        queue: ?*anyopaque,
        destructor: ?*anyopaque,
    ) !*Data {
        return dispatch_data_create(
            data.ptr,
            data.len,
            queue,
            destructor,
        ) orelse return error.OutOfMemory;
    }

    pub fn release(data: *Data) void {
        foundation.c.CFRelease(data);
    }
};

extern "c" fn dispatch_data_create(
    data: [*]const u8,
    len: usize,
    queue: ?*anyopaque,
    destructor: ?*anyopaque,
) ?*Data;
