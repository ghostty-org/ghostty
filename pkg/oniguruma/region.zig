const std = @import("std");
const c = @import("c.zig");

pub const Region = extern struct {
    allocated: c_int = 0,
    num_regs: c_int = 0,
    beg: ?[*]c_int = null,
    end: ?[*]c_int = null,
    history_root: ?*c.OnigCaptureTreeNode = null, // TODO: convert to Zig

    pub fn deinit(self: *Region) void {
        // We never free ourself because allocation of Region in the Zig
        // bindings is handled by the Zig program.
        c.onig_region_free(@ptrCast(self), 0);
    }

    /// Count the number of matches
    pub fn count(self: *const Region) usize {
        return @intCast(self.num_regs);
    }

    /// Iterate over the matched ranges.
    pub fn iterator(self: *const Region) Iterator {
        return .{ .region = self };
    }

    pub fn starts(self: *const Region) []const c_int {
        if (self.num_regs == 0) return &.{};
        return self.beg.?[0..@intCast(self.num_regs)];
    }

    pub fn ends(self: *const Region) []const c_int {
        if (self.num_regs == 0) return &.{};
        return self.end.?[0..@intCast(self.num_regs)];
    }

    pub const Iterator = struct {
        region: *const Region,
        i: usize = 0,

        /// The next range
        pub fn next(self: *Iterator) ?[2]usize {
            if (self.i >= self.region.num_regs) return null;
            defer self.i += 1;
            return .{
                @intCast(self.region.beg.?[self.i]),
                @intCast(self.region.end.?[self.i]),
            };
        }
    };
};
