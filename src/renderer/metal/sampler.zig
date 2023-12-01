const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const objc = @import("objc");

const mtl = @import("api.zig");

pub const Sampler = struct {
    sampler: objc.Object,

    pub fn init(device: objc.Object) !Sampler {
        const desc = init: {
            const Class = objc.getClass("MTLSamplerDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };
        defer desc.msgSend(void, objc.sel("release"), .{});
        desc.setProperty("rAddressMode", @intFromEnum(mtl.MTLSamplerAddressMode.clamp_to_edge));
        desc.setProperty("sAddressMode", @intFromEnum(mtl.MTLSamplerAddressMode.clamp_to_edge));
        desc.setProperty("tAddressMode", @intFromEnum(mtl.MTLSamplerAddressMode.clamp_to_edge));
        desc.setProperty("minFilter", @intFromEnum(mtl.MTLSamplerMinMagFilter.linear));
        desc.setProperty("magFilter", @intFromEnum(mtl.MTLSamplerMinMagFilter.linear));

        const sampler = device.msgSend(
            objc.Object,
            objc.sel("newSamplerStateWithDescriptor:"),
            .{desc},
        );
        errdefer sampler.msgSend(void, objc.sel("release"), .{});

        return .{ .sampler = sampler };
    }

    pub fn deinit(self: *Sampler) void {
        self.sampler.msgSend(void, objc.sel("release"), .{});
    }
};
