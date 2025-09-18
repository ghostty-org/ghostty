const Sampler = @This();

const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const glad = @import("glad.zig");
const Texture = @import("Texture.zig");

id: c.GLuint,

/// Create a single sampler.
pub fn create() errors.Error!Sampler {
    var id: c.GLuint = undefined;
    glad.context.GenSamplers.?(1, &id);
    try errors.getError();
    return .{ .id = id };
}

/// glBindSampler
pub fn bind(v: Sampler, index: c_uint) !void {
    glad.context.BindSampler.?(index, v.id);
    try errors.getError();
}

pub fn parameter(
    self: Sampler,
    name: Texture.Parameter,
    value: anytype,
) errors.Error!void {
    switch (@TypeOf(value)) {
        c.GLint => glad.context.SamplerParameteri.?(
            self.id,
            @intFromEnum(name),
            value,
        ),
        else => unreachable,
    }
    try errors.getError();
}

pub fn destroy(v: Sampler) void {
    glad.context.DeleteSamplers.?(1, &v.id);
}
