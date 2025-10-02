const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig").c;

pub const Run = opaque {
    pub fn release(self: *Run) void {
        foundation.CFRelease(self);
    }

    pub fn getGlyphCount(self: *Run) usize {
        return @intCast(c.CTRunGetGlyphCount(@ptrCast(self)));
    }

    pub fn getGlyphsPtr(self: *Run) ?[]const graphics.Glyph {
        const len = self.getGlyphCount();
        if (len == 0) return &.{};
        const ptr: [*c]const graphics.Glyph = @ptrCast(
            c.CTRunGetGlyphsPtr(@ptrCast(self)),
        );
        if (ptr == null) return null;
        return ptr[0..len];
    }

    pub fn getGlyphs(self: *Run, alloc: Allocator) ![]const graphics.Glyph {
        const len = self.getGlyphCount();
        const ptr = try alloc.alloc(graphics.Glyph, len);
        errdefer alloc.free(ptr);
        c.CTRunGetGlyphs(
            @ptrCast(self),
            .{ .location = 0, .length = 0 },
            @ptrCast(ptr.ptr),
        );
        return ptr;
    }

    pub fn getPositionsPtr(self: *Run) ?[]const graphics.Point {
        const len = self.getGlyphCount();
        if (len == 0) return &.{};
        const ptr: [*c]const graphics.Point = @ptrCast(
            c.CTRunGetPositionsPtr(@ptrCast(self)),
        );
        if (ptr == null) return null;
        return ptr[0..len];
    }

    pub fn getPositions(self: *Run, alloc: Allocator) ![]const graphics.Point {
        const len = self.getGlyphCount();
        const ptr = try alloc.alloc(graphics.Point, len);
        errdefer alloc.free(ptr);
        c.CTRunGetPositions(
            @ptrCast(self),
            .{ .location = 0, .length = 0 },
            @ptrCast(ptr.ptr),
        );
        return ptr;
    }

    pub fn getAdvancesPtr(self: *Run) ?[]const graphics.Size {
        const len = self.getGlyphCount();
        if (len == 0) return &.{};
        const ptr: [*c]const graphics.Size = @ptrCast(
            c.CTRunGetAdvancesPtr(@ptrCast(self)),
        );
        if (ptr == null) return null;
        return ptr[0..len];
    }

    pub fn getAdvances(self: *Run, alloc: Allocator) ![]const graphics.Size {
        const len = self.getGlyphCount();
        const ptr = try alloc.alloc(graphics.Size, len);
        errdefer alloc.free(ptr);
        c.CTRunGetAdvances(
            @ptrCast(self),
            .{ .location = 0, .length = 0 },
            @ptrCast(ptr.ptr),
        );
        return ptr;
    }

    pub fn getStringIndicesPtr(self: *Run) ?[]const usize {
        const len = self.getGlyphCount();
        if (len == 0) return &.{};
        const ptr: [*c]const usize = @ptrCast(
            c.CTRunGetStringIndicesPtr(@ptrCast(self)),
        );
        if (ptr == null) return null;
        return ptr[0..len];
    }

    pub fn getStringIndices(self: *Run, alloc: Allocator) ![]const usize {
        const len = self.getGlyphCount();
        const ptr = try alloc.alloc(usize, len);
        errdefer alloc.free(ptr);
        c.CTRunGetStringIndices(
            @ptrCast(self),
            .{ .location = 0, .length = 0 },
            @ptrCast(ptr.ptr),
        );
        return ptr;
    }

    pub fn getStatus(self: *Run) Status {
        return @bitCast(c.CTRunGetStatus(@ptrCast(self)));
    }
};

/// https://developer.apple.com/documentation/coretext/ctrunstatus?language=objc
pub const Status = packed struct(u32) {
    right_to_left: bool,
    non_monotonic: bool,
    has_non_identity_matrix: bool,
    _pad: u29 = 0,
};
