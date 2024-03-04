const builtin = @import("builtin");

pub usingnamespace @import("sanitize.zig");

const charsets = @import("charsets.zig");
const stream = @import("stream.zig");
const ansi = @import("ansi.zig");
const csi = @import("csi.zig");
const sgr = @import("sgr.zig");
pub const apc = @import("apc.zig");
pub const dcs = @import("dcs.zig");
pub const osc = @import("osc.zig");
pub const point = @import("point.zig");
pub const color = @import("color.zig");
pub const device_status = @import("device_status.zig");
pub const kitty = @import("kitty.zig");
pub const modes = @import("modes.zig");
pub const parse_table = @import("parse_table.zig");
pub const x11_color = @import("x11_color.zig");

pub const Charset = charsets.Charset;
pub const CharsetSlot = charsets.Slots;
pub const CharsetActiveSlot = charsets.ActiveSlot;
pub const CSI = Parser.Action.CSI;
pub const DCS = Parser.Action.DCS;
pub const MouseShape = @import("mouse_shape.zig").MouseShape;
pub const Terminal = @import("Terminal.zig");
//pub const Terminal = new.Terminal;
pub const Parser = @import("Parser.zig");
pub const Selection = @import("Selection.zig");
pub const Screen = @import("Screen.zig");
pub const StringMap = @import("StringMap.zig");
pub const Stream = stream.Stream;
pub const Cursor = Screen.Cursor;
pub const CursorStyleReq = ansi.CursorStyle;
pub const DeviceAttributeReq = ansi.DeviceAttributeReq;
pub const Mode = modes.Mode;
pub const ModifyKeyFormat = ansi.ModifyKeyFormat;
pub const ProtectedMode = ansi.ProtectedMode;
pub const StatusLineType = ansi.StatusLineType;
pub const StatusDisplay = ansi.StatusDisplay;
pub const EraseDisplay = csi.EraseDisplay;
pub const EraseLine = csi.EraseLine;
pub const TabClear = csi.TabClear;
pub const Attribute = sgr.Attribute;

/// If we're targeting wasm then we export some wasm APIs.
pub usingnamespace if (builtin.target.isWasm()) struct {
    pub usingnamespace @import("wasm.zig");
} else struct {};

/// The new stuff. TODO: remove this before merge.
pub const new = @import("new/main.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
