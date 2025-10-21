const std = @import("std");
const config = @import("config.zig");
const config_x = @import("config.x.zig");
const d = config.default;
const wcwidth = config_x.wcwidth;

const Allocator = std.mem.Allocator;

fn computeWidth(
    alloc: std.mem.Allocator,
    cp: u21,
    data: anytype,
    backing: anytype,
    tracking: anytype,
) Allocator.Error!void {
    _ = alloc;
    _ = cp;
    _ = backing;
    _ = tracking;
    data.width = @intCast(@min(2, @max(0, data.wcwidth)));
}

const width = config.Extension{
    .inputs = &.{"wcwidth"},
    .compute = &computeWidth,
    .fields = &.{
        .{ .name = "width", .type = u2 },
    },
};

fn computeIsSymbol(
    alloc: Allocator,
    cp: u21,
    data: anytype,
    backing: anytype,
    tracking: anytype,
) Allocator.Error!void {
    _ = alloc;
    _ = cp;
    _ = backing;
    _ = tracking;
    const block = data.block;
    data.is_symbol = data.general_category == .other_private_use or
        block == .arrows or
        block == .dingbats or
        block == .emoticons or
        block == .miscellaneous_symbols or
        block == .enclosed_alphanumerics or
        block == .enclosed_alphanumeric_supplement or
        block == .miscellaneous_symbols_and_pictographs or
        block == .transport_and_map_symbols;
}

const is_symbol = config.Extension{
    .inputs = &.{ "block", "general_category" },
    .compute = &computeIsSymbol,
    .fields = &.{
        .{ .name = "is_symbol", .type = bool },
    },
};

pub const tables = [_]config.Table{
    .{
        .name = "runtime",
        .extensions = &.{},
        .fields = &.{
            d.field("is_emoji_presentation"),
            d.field("case_folding_full"),
        },
    },
    .{
        .name = "buildtime",
        .extensions = &.{ wcwidth, width, is_symbol },
        .fields = &.{
            width.field("width"),
            d.field("grapheme_break"),
            is_symbol.field("is_symbol"),
            d.field("is_emoji_modifier"),
            d.field("is_emoji_modifier_base"),
        },
    },
};
