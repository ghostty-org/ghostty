const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const video = @import("../video.zig");

pub const IOSurface = opaque {
    pub const Error = error{
        InvalidOperation,
    };

    pub const Properties = struct {
        width: c_int,
        height: c_int,
        pixel_format: video.PixelFormat,
        bytes_per_element: c_int,
        colorspace: ?*graphics.ColorSpace,
    };

    pub fn init(properties: Properties) Allocator.Error!*IOSurface {
        var w = try foundation.Number.create(.int, &properties.width);
        defer w.release();
        var h = try foundation.Number.create(.int, &properties.height);
        defer h.release();
        var pf = try foundation.Number.create(.int, &@as(c_int, @intFromEnum(properties.pixel_format)));
        defer pf.release();
        var bpe = try foundation.Number.create(.int, &properties.bytes_per_element);
        defer bpe.release();

        var properties_dict = try foundation.Dictionary.create(
            &[_]?*const anyopaque{
                c.kIOSurfaceWidth,
                c.kIOSurfaceHeight,
                c.kIOSurfacePixelFormat,
                c.kIOSurfaceBytesPerElement,
            },
            &[_]?*const anyopaque{ w, h, pf, bpe },
        );
        defer properties_dict.release();

        var surface = @as(?*IOSurface, @ptrFromInt(@intFromPtr(
            c.IOSurfaceCreate(@ptrCast(properties_dict)),
        ))) orelse return error.OutOfMemory;

        if (properties.colorspace) |space| {
            surface.setColorSpace(space);
        }

        return surface;
    }

    pub fn deinit(self: *IOSurface) void {
        // We mark it purgeable so that it is immediately unloaded, so that we
        // don't have to wait for CoreFoundation garbage collection to trigger.
        _ = c.IOSurfaceSetPurgeable(
            @ptrCast(self),
            c.kIOSurfacePurgeableEmpty,
            null,
        );
        foundation.CFRelease(self);
    }

    pub fn retain(self: *IOSurface) void {
        foundation.CFRetain(self);
    }

    pub fn release(self: *IOSurface) void {
        foundation.CFRelease(self);
    }

    pub fn setColorSpace(self: *IOSurface, colorspace: *graphics.ColorSpace) void {
        const serialized_colorspace = graphics.c.CGColorSpaceCopyPropertyList(
            @ptrCast(colorspace),
        ).?;
        defer foundation.CFRelease(@constCast(serialized_colorspace));

        c.IOSurfaceSetValue(
            @ptrCast(self),
            c.kIOSurfaceColorSpace,
            @ptrCast(serialized_colorspace),
        );
    }

    pub inline fn lock(self: *IOSurface) void {
        c.IOSurfaceLock(
            @ptrCast(self),
            0,
            null,
        );
    }
    pub inline fn unlock(self: *IOSurface) void {
        c.IOSurfaceUnlock(
            @ptrCast(self),
            0,
            null,
        );
    }

    pub inline fn getAllocSize(self: *IOSurface) usize {
        return c.IOSurfaceGetAllocSize(@ptrCast(self));
    }

    pub inline fn getWidth(self: *IOSurface) usize {
        return c.IOSurfaceGetWidth(@ptrCast(self));
    }

    pub inline fn getHeight(self: *IOSurface) usize {
        return c.IOSurfaceGetHeight(@ptrCast(self));
    }

    pub inline fn getBytesPerElement(self: *IOSurface) usize {
        return c.IOSurfaceGetBytesPerElement(@ptrCast(self));
    }

    pub inline fn getBytesPerRow(self: *IOSurface) usize {
        return c.IOSurfaceGetBytesPerRow(@ptrCast(self));
    }

    pub inline fn getBaseAddress(self: *IOSurface) ?[*]u8 {
        return @ptrCast(c.IOSurfaceGetBaseAddress(@ptrCast(self)));
    }

    pub inline fn getElementWidth(self: *IOSurface) usize {
        return c.IOSurfaceGetElementWidth(@ptrCast(self));
    }

    pub inline fn getElementHeight(self: *IOSurface) usize {
        return c.IOSurfaceGetElementHeight(@ptrCast(self));
    }

    pub inline fn getPixelFormat(self: *IOSurface) video.PixelFormat {
        return @enumFromInt(c.IOSurfaceGetPixelFormat(@ptrCast(self)));
    }
};
