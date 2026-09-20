const Self = @This();

const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");

pub const Options = struct {
    context: *Context,
    min_filter: c.VkFilter,
    mag_filter: c.VkFilter,
    address_mode: c.VkSamplerAddressMode,
};

context: *Context,
sampler: c.VkSampler,

pub const Error = anyerror;

pub fn init(opts: Options) Error!Self {
    var info = std.mem.zeroes(c.VkSamplerCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    info.magFilter = opts.mag_filter;
    info.minFilter = opts.min_filter;
    info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
    info.addressModeU = opts.address_mode;
    info.addressModeV = opts.address_mode;
    info.addressModeW = opts.address_mode;
    info.maxLod = 0;

    var sampler: c.VkSampler = null;
    try Context.result(c.vkCreateSampler(opts.context.device, &info, null, &sampler));
    return .{ .context = opts.context, .sampler = sampler };
}

pub fn deinit(self: Self) void {
    c.vkDestroySampler(self.context.device, self.sampler, null);
}
