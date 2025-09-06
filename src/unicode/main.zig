pub const lut = @import("lut.zig");

const grapheme = @import("grapheme.zig");
const props = @import("props.zig");
pub const table = props.table;
pub const Properties = props.Properties;
pub const getProperties = props.get;
pub const graphemeBreak = grapheme.graphemeBreak;
pub const GraphemeBreakState = grapheme.BreakState;

test {
    _ = @import("symbols.zig");
    @import("std").testing.refAllDecls(@This());
}
