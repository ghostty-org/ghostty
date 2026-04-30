const c = @import("c.zig").c;
const errors = @import("errors.zig");
const Error = errors.Error;

pub const MatchParam = struct {
    value: *c.OnigMatchParam,

    pub fn init() !MatchParam {
        const value = c.onig_new_match_param() orelse return Error.Memory;
        return .{ .value = value };
    }

    pub fn deinit(self: *MatchParam) void {
        c.onig_free_match_param(self.value);
    }

    pub fn setRetryLimitInSearch(self: *MatchParam, limit: usize) !void {
        _ = try errors.convertError(c.onig_set_retry_limit_in_search_of_match_param(
            self.value,
            @intCast(limit),
        ));
    }
};
