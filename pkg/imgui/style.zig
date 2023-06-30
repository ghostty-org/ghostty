const std = @import("std");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;

pub const Style = opaque {
    pub fn get() Allocator.Error!*Style {
        return @as(
            ?*Style,
            @ptrCast(c.igGetStyle()),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn colorsDark(self: *Style) void {
        c.igStyleColorsDark(self.cval());
    }

    pub fn colorsLight(self: *Style) void {
        c.igStyleColorsLight(self.cval());
    }

    pub fn colorsClassic(self: *Style) void {
        c.igStyleColorsClassic(self.cval());
    }

    pub fn scaleAllSizes(self: *Style, factor: f32) void {
        c.ImGuiStyle_ScaleAllSizes(self.cval(), factor);
    }

    pub inline fn cval(self: *Style) *c.ImGuiStyle {
        return @as(
            *c.ImGuiStyle,
            @ptrCast(@alignCast(self)),
        );
    }
};
