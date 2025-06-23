const builtin = @import("builtin");

const charsets = @import("charsets.zig");
const sanitize = @import("sanitize.zig");
const stream = @import("stream.zig");
const ansi = @import("ansi.zig");
const csi = @import("csi.zig");
const hyperlink = @import("hyperlink.zig");
const sgr = @import("sgr.zig");
const style = @import("style.zig");
pub const apc = @import("apc.zig");
pub const dcs = @import("dcs.zig");
pub const osc = @import("osc.zig");
pub const point = @import("point.zig");
pub const color = @import("color.zig");
pub const device_status = @import("device_status.zig");
pub const kitty = @import("kitty.zig");
pub const modes = @import("modes.zig");
pub const page = @import("page.zig");
pub const parse_table = @import("parse_table.zig");
pub const search = @import("search.zig");
pub const size = @import("size.zig");
pub const tmux = @import("tmux.zig");
pub const x11_color = @import("x11_color.zig");

pub const Charset = charsets.Charset;
pub const CharsetSlot = charsets.Slots;
pub const CharsetActiveSlot = charsets.ActiveSlot;
pub const Cell = page.Cell;
pub const Coordinate = point.Coordinate;
pub const CSI = Parser.Action.CSI;
pub const DCS = Parser.Action.DCS;
pub const MouseShape = @import("mouse_shape.zig").MouseShape;
pub const Page = page.Page;
pub const PageList = @import("PageList.zig");
pub const Parser = @import("Parser.zig");
pub const Pin = PageList.Pin;
pub const Point = point.Point;
pub const Screen = @import("Screen.zig");
pub const ScreenType = Terminal.ScreenType;
pub const Selection = @import("Selection.zig");
pub const SizeReportStyle = csi.SizeReportStyle;
pub const StringMap = @import("StringMap.zig");
pub const Style = style.Style;
pub const Terminal = @import("Terminal.zig");
pub const Stream = stream.Stream;
pub const Cursor = Screen.Cursor;
pub const CursorStyle = Screen.CursorStyle;
pub const CursorStyleReq = ansi.CursorStyle;
pub const DeviceAttributeReq = ansi.DeviceAttributeReq;
pub const Mode = modes.Mode;
pub const ModePacked = modes.ModePacked;
pub const ModifyKeyFormat = ansi.ModifyKeyFormat;
pub const ProtectedMode = ansi.ProtectedMode;
pub const StatusLineType = ansi.StatusLineType;
pub const StatusDisplay = ansi.StatusDisplay;
pub const EraseDisplay = csi.EraseDisplay;
pub const EraseLine = csi.EraseLine;
pub const TabClear = csi.TabClear;
pub const Attribute = sgr.Attribute;

pub const isSafePaste = sanitize.isSafePaste;

test {
    @import("std").testing.refAllDecls(@This());

    // Internals
    _ = @import("bitmap_allocator.zig");
    _ = @import("hash_map.zig");
    _ = @import("ref_counted_set.zig");
    _ = @import("size.zig");
}
