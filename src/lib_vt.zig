//! This is the public API of the ghostty-vt Zig module.
//!
//! WARNING: The API is not guaranteed to be stable.
//!
//! The functionality is extremely stable, since it is extracted
//! directly from Ghostty which has been used in real world scenarios
//! by thousands of users for years. However, the API itself (functions,
//! types, etc.) may change without warning. We're working on stabilizing
//! this in the future.
const lib = @This();

// The public API below reproduces a lot of terminal/main.zig but
// is separate because (1) we need our root file to be in `src/`
// so we can access other directories and (2) we may want to withhold
// parts of `terminal` that are not ready for public consumption
// or are too Ghostty-internal.
const terminal = @import("terminal/main.zig");

pub const apc = terminal.apc;
pub const dcs = terminal.dcs;
pub const osc = terminal.osc;
pub const point = terminal.point;
pub const color = terminal.color;
pub const device_status = terminal.device_status;
pub const kitty = terminal.kitty;
pub const modes = terminal.modes;
pub const page = terminal.page;
pub const parse_table = terminal.parse_table;
pub const search = terminal.search;
pub const size = terminal.size;
pub const x11_color = terminal.x11_color;

pub const Charset = terminal.Charset;
pub const CharsetSlot = terminal.CharsetSlot;
pub const CharsetActiveSlot = terminal.CharsetActiveSlot;
pub const Cell = page.Cell;
pub const Coordinate = point.Coordinate;
pub const CSI = Parser.Action.CSI;
pub const DCS = Parser.Action.DCS;
pub const MouseShape = terminal.MouseShape;
pub const Page = page.Page;
pub const PageList = terminal.PageList;
pub const Parser = terminal.Parser;
pub const Pin = PageList.Pin;
pub const Point = point.Point;
pub const Screen = terminal.Screen;
pub const ScreenType = Terminal.ScreenType;
pub const Selection = terminal.Selection;
pub const SizeReportStyle = terminal.SizeReportStyle;
pub const StringMap = terminal.StringMap;
pub const Style = terminal.Style;
pub const Terminal = terminal.Terminal;
pub const Stream = terminal.Stream;
pub const Cursor = Screen.Cursor;
pub const CursorStyle = Screen.CursorStyle;
pub const CursorStyleReq = terminal.CursorStyle;
pub const DeviceAttributeReq = terminal.DeviceAttributeReq;
pub const Mode = modes.Mode;
pub const ModePacked = modes.ModePacked;
pub const ModifyKeyFormat = terminal.ModifyKeyFormat;
pub const ProtectedMode = terminal.ProtectedMode;
pub const StatusLineType = terminal.StatusLineType;
pub const StatusDisplay = terminal.StatusDisplay;
pub const EraseDisplay = terminal.EraseDisplay;
pub const EraseLine = terminal.EraseLine;
pub const TabClear = terminal.TabClear;
pub const Attribute = terminal.Attribute;

/// Terminal-specific input encoding is also part of libghostty-vt.
pub const input = struct {
    // We have to be careful to only import targeted files within
    // the input package because the full package brings in too many
    // other dependencies.
    const paste = @import("input/paste.zig");
    const key = @import("input/key.zig");
    const key_encode = @import("input/key_encode.zig");

    // Paste-related APIs
    pub const PasteError = paste.Error;
    pub const PasteOptions = paste.Options;
    pub const isSafePaste = paste.isSafe;
    pub const encodePaste = paste.encode;

    // Key encoding
    pub const Key = key.Key;
    pub const KeyAction = key.Action;
    pub const KeyEvent = key.KeyEvent;
    pub const KeyMods = key.Mods;
    pub const KeyEncodeOptions = key_encode.Options;
    pub const encodeKey = key_encode.encode;
};

comptime {
    // If we're building the C library (vs. the Zig module) then
    // we want to reference the C API so that it gets exported.
    if (@import("root") == lib) {
        const c = terminal.c_api;
        @export(&c.osc_new, .{ .name = "ghostty_osc_new" });
        @export(&c.osc_free, .{ .name = "ghostty_osc_free" });
        @export(&c.osc_next, .{ .name = "ghostty_osc_next" });
        @export(&c.osc_reset, .{ .name = "ghostty_osc_reset" });
        @export(&c.osc_end, .{ .name = "ghostty_osc_end" });
        @export(&c.osc_command_type, .{ .name = "ghostty_osc_command_type" });
        @export(&c.osc_command_data, .{ .name = "ghostty_osc_command_data" });
        @export(&c.key_event_new, .{ .name = "ghostty_key_event_new" });
        @export(&c.key_event_free, .{ .name = "ghostty_key_event_free" });
        @export(&c.key_event_set_action, .{ .name = "ghostty_key_event_set_action" });
        @export(&c.key_event_get_action, .{ .name = "ghostty_key_event_get_action" });
        @export(&c.key_event_set_key, .{ .name = "ghostty_key_event_set_key" });
        @export(&c.key_event_get_key, .{ .name = "ghostty_key_event_get_key" });
        @export(&c.key_event_set_mods, .{ .name = "ghostty_key_event_set_mods" });
        @export(&c.key_event_get_mods, .{ .name = "ghostty_key_event_get_mods" });
        @export(&c.key_event_set_consumed_mods, .{ .name = "ghostty_key_event_set_consumed_mods" });
        @export(&c.key_event_get_consumed_mods, .{ .name = "ghostty_key_event_get_consumed_mods" });
        @export(&c.key_event_set_composing, .{ .name = "ghostty_key_event_set_composing" });
        @export(&c.key_event_get_composing, .{ .name = "ghostty_key_event_get_composing" });
        @export(&c.key_event_set_utf8, .{ .name = "ghostty_key_event_set_utf8" });
        @export(&c.key_event_get_utf8, .{ .name = "ghostty_key_event_get_utf8" });
        @export(&c.key_event_set_unshifted_codepoint, .{ .name = "ghostty_key_event_set_unshifted_codepoint" });
        @export(&c.key_event_get_unshifted_codepoint, .{ .name = "ghostty_key_event_get_unshifted_codepoint" });
        @export(&c.key_encoder_new, .{ .name = "ghostty_key_encoder_new" });
        @export(&c.key_encoder_free, .{ .name = "ghostty_key_encoder_free" });
        @export(&c.key_encoder_setopt, .{ .name = "ghostty_key_encoder_setopt" });
        @export(&c.key_encoder_encode, .{ .name = "ghostty_key_encoder_encode" });
        @export(&c.paste_is_safe, .{ .name = "ghostty_paste_is_safe" });
    }
}

test {
    _ = terminal;
    _ = @import("lib/main.zig");
    @import("std").testing.refAllDecls(input);
    if (comptime terminal.options.c_abi) {
        _ = terminal.c_api;
    }
}
