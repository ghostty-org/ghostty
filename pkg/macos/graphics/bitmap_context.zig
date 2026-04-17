const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const graphics = @import("../graphics.zig");
const Context = @import("context.zig").Context;
const c = @import("c");

pub const BitmapContext = opaque {
    pub const context = Context(BitmapContext);

    pub fn create(
        data: ?[]u8,
        width: usize,
        height: usize,
        bits_per_component: usize,
        bytes_per_row: usize,
        space: *graphics.ColorSpace,
        opts: c_uint,
    ) Allocator.Error!*BitmapContext {
        return @as(
            ?*BitmapContext,
            @ptrFromInt(@intFromPtr(c.CGBitmapContextCreate(
                @ptrCast(if (data) |d| d.ptr else null),
                width,
                height,
                bits_per_component,
                bytes_per_row,
                @ptrCast(space),
                opts,
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }
};

test {
    //const testing = std.testing;

    const cs = try graphics.ColorSpace.createDeviceGray();
    defer cs.release();
    const ctx = try BitmapContext.create(null, 80, 80, 8, 80, cs, 0);
    const context = BitmapContext.context;
    defer context.release(ctx);
    context.setShouldAntialias(ctx, true);
    context.setShouldSmoothFonts(ctx, false);
    context.setGrayFillColor(ctx, 1, 1);
    context.setGrayStrokeColor(ctx, 1, 1);
    context.setTextDrawingMode(ctx, .fill);
    context.setTextMatrix(ctx, graphics.AffineTransform.identity());
    context.setTextPosition(ctx, 0, 0);
}
