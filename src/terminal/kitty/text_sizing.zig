//! Kitty's text sizing protocol (OSC 66)
//! Specification: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/

const std = @import("std");
const build_options = @import("terminal_options");

const encoding = @import("encoding.zig");
const lib = @import("../../lib/main.zig");
const lib_target: lib.Target = if (build_options.c_abi) .c else .zig;

const log = std.log.scoped(.kitty_text_sizing);

pub const max_payload_length = 4096;

pub const VAlign = lib.Enum(lib_target, &.{
    "top",
    "bottom",
    "center",
});

pub const HAlign = lib.Enum(lib_target, &.{
    "left",
    "right",
    "center",
});

pub const OSC = struct {
    scale: u3 = 1, // 1 - 7
    width: u3 = 0, // 0 - 7 (0 means default)
    numerator: u4 = 0,
    denominator: u4 = 0,
    valign: VAlign = .top,
    halign: HAlign = .left,
    text: [:0]const u8,

    /// We don't currently support encoding this to C in any way.
    pub const C = void;

    pub fn cval(_: OSC) C {
        return {};
    }

    pub fn set(self: *OSC, key: u8, value: []const u8) !void {
        const v = std.fmt.parseInt(
            u4,
            value,
            10,
        ) catch return error.InvalidValue;

        switch (key) {
            's' => self.scale = std.math.cast(u3, v) orelse return error.InvalidValue,
            'w' => self.width = std.math.cast(u3, v) orelse return error.InvalidValue,
            'n' => self.numerator = v,
            'd' => self.denominator = v,
            'v' => self.valign = std.enums.fromInt(VAlign, v) orelse return error.InvalidValue,
            'h' => self.halign = std.enums.fromInt(HAlign, v) orelse return error.InvalidValue,
            else => return error.UnknownKey,
        }
    }

    pub fn validate(self: OSC) bool {
        if (self.text.len > max_payload_length) {
            @branchHint(.cold);
            log.warn("kitty text sizing payload exceeds maximum size", .{});
            return false;
        }

        if (!encoding.isUrlSafeUtf8(self.text)) {
            @branchHint(.cold);
            log.warn("kitty text sizing payload is not URL-safe UTF-8", .{});
            return false;
        }

        if (self.scale == 0) {
            @branchHint(.cold);
            log.warn("kitty text sizing cannot have 0 scale", .{});
            return false;
        }
        return true;
    }
};
