const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const graphics = @import("../graphics.zig");
const c = @import("c.zig").c;

/// Returns a struct that has all the shared context functions for the
/// given type.
pub fn Context(comptime T: type) type {
    return struct {
        value: *T,

        pub fn release(self: *T) void {
            c.CGContextRelease(@ptrCast(self));
        }

        pub fn setLineWidth(self: *T, width: f64) void {
            c.CGContextSetLineWidth(
                @ptrCast(self),
                width,
            );
        }

        pub fn setAllowsAntialiasing(self: *T, v: bool) void {
            c.CGContextSetAllowsAntialiasing(
                @ptrCast(self),
                v,
            );
        }

        pub fn setAllowsFontSmoothing(self: *T, v: bool) void {
            c.CGContextSetAllowsFontSmoothing(
                @ptrCast(self),
                v,
            );
        }

        pub fn setAllowsFontSubpixelPositioning(self: *T, v: bool) void {
            c.CGContextSetAllowsFontSubpixelPositioning(
                @ptrCast(self),
                v,
            );
        }

        pub fn setAllowsFontSubpixelQuantization(self: *T, v: bool) void {
            c.CGContextSetAllowsFontSubpixelQuantization(
                @ptrCast(self),
                v,
            );
        }

        pub fn setShouldAntialias(self: *T, v: bool) void {
            c.CGContextSetShouldAntialias(
                @ptrCast(self),
                v,
            );
        }

        pub fn setShouldSmoothFonts(self: *T, v: bool) void {
            c.CGContextSetShouldSmoothFonts(
                @ptrCast(self),
                v,
            );
        }

        pub fn setShouldSubpixelPositionFonts(self: *T, v: bool) void {
            c.CGContextSetShouldSubpixelPositionFonts(
                @ptrCast(self),
                v,
            );
        }

        pub fn setShouldSubpixelQuantizeFonts(self: *T, v: bool) void {
            c.CGContextSetShouldSubpixelQuantizeFonts(
                @ptrCast(self),
                v,
            );
        }

        pub fn setGrayFillColor(self: *T, gray: f64, alpha: f64) void {
            c.CGContextSetGrayFillColor(
                @ptrCast(self),
                gray,
                alpha,
            );
        }

        pub fn setGrayStrokeColor(self: *T, gray: f64, alpha: f64) void {
            c.CGContextSetGrayStrokeColor(
                @ptrCast(self),
                gray,
                alpha,
            );
        }

        pub fn setRGBFillColor(self: *T, r: f64, g: f64, b: f64, alpha: f64) void {
            c.CGContextSetRGBFillColor(
                @ptrCast(self),
                r,
                g,
                b,
                alpha,
            );
        }

        pub fn setRGBStrokeColor(self: *T, r: f64, g: f64, b: f64, alpha: f64) void {
            c.CGContextSetRGBStrokeColor(
                @ptrCast(self),
                r,
                g,
                b,
                alpha,
            );
        }

        pub fn setTextDrawingMode(self: *T, mode: TextDrawingMode) void {
            c.CGContextSetTextDrawingMode(
                @ptrCast(self),
                @intFromEnum(mode),
            );
        }

        pub fn setTextMatrix(self: *T, matrix: graphics.AffineTransform) void {
            c.CGContextSetTextMatrix(
                @ptrCast(self),
                @bitCast(matrix),
            );
        }

        pub fn setTextPosition(self: *T, x: f64, y: f64) void {
            c.CGContextSetTextPosition(
                @ptrCast(self),
                x,
                y,
            );
        }

        pub fn fillRect(self: *T, rect: graphics.Rect) void {
            c.CGContextFillRect(
                @ptrCast(self),
                @bitCast(rect),
            );
        }

        pub fn scaleCTM(self: *T, sx: c.CGFloat, sy: c.CGFloat) void {
            c.CGContextScaleCTM(
                @ptrCast(self),
                sx,
                sy,
            );
        }

        pub fn translateCTM(self: *T, tx: c.CGFloat, ty: c.CGFloat) void {
            c.CGContextTranslateCTM(
                @ptrCast(self),
                tx,
                ty,
            );
        }
    };
}

pub const TextDrawingMode = enum(c_int) {
    fill = c.kCGTextFill,
    stroke = c.kCGTextStroke,
    fill_stroke = c.kCGTextFillStroke,
    invisible = c.kCGTextInvisible,
    fill_clip = c.kCGTextFillClip,
    stroke_clip = c.kCGTextStrokeClip,
    fill_stroke_clip = c.kCGTextFillStrokeClip,
    clip = c.kCGTextClip,
};
