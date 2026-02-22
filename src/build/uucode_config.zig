const std = @import("std");
const assert = std.debug.assert;
const config = @import("config.zig");
const config_x = @import("config.x.zig");
const d = config.default;
const wcwidth = config_x.wcwidth;
const grapheme_break_no_control = config_x.grapheme_break_no_control;

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

    // This condition is needed as Ghostty currently has a singular concept for
    // the `width` of a code point, while `uucode` splits the concept into
    // `wcwidth_standalone` and `wcwidth_zero_in_grapheme`. The two cases where
    // we want to use the `wcwidth_standalone` despite the code point occupying
    // zero width in a grapheme (`wcwidth_zero_in_grapheme`) are emoji
    // modifiers and prepend code points. For emoji modifiers we want to
    // support displaying them in isolation as color patches, and if prepend
    // characters were to be width 0 they would disappear from the output with
    // Ghostty's current width 0 handling. Future work will take advantage of
    // the new uucode `wcwidth_standalone` vs `wcwidth_zero_in_grapheme` split.
    if (data.wcwidth_zero_in_grapheme and !data.is_emoji_modifier and data.grapheme_break_no_control != .prepend) {
        data.width = 0;
    } else {
        data.width = @min(2, data.wcwidth_standalone);
    }
}

const width = config.Extension{
    .inputs = &.{
        "wcwidth_standalone",
        "wcwidth_zero_in_grapheme",
        "is_emoji_modifier",
        "grapheme_break_no_control",
    },
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
        .extensions = &.{
            wcwidth,
            grapheme_break_no_control,
            width,
            is_symbol,
        },
        .fields = &.{
            width.field("width"),
            wcwidth.field("wcwidth_zero_in_grapheme"),
            grapheme_break_no_control.field("grapheme_break_no_control"),
            is_symbol.field("is_symbol"),
            d.field("is_emoji_vs_base"),
        },
    },
};
