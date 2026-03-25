const initpkg = @import("init.zig");
const match_param = @import("match_param.zig");
const regex = @import("regex.zig");
const region = @import("region.zig");
const types = @import("types.zig");

pub const c = @import("c.zig");
pub const testing = @import("testing.zig");
pub const errors = @import("errors.zig");

pub const init = initpkg.init;
pub const deinit = initpkg.deinit;
pub const Encoding = types.Encoding;
pub const MatchParam = match_param.MatchParam;
pub const Regex = regex.Regex;
pub const Region = region.Region;
pub const Syntax = types.Syntax;

test {
    @import("std").testing.refAllDecls(@This());
}
