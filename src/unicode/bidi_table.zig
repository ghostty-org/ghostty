const BidiProperties = @import("bidi_props.zig").BidiProperties;
const lut = @import("lut.zig");

/// The bidi lookup tables for Ghostty.
pub const table = table: {
    // This is only available after running a generator as part of the Ghostty
    // build.zig process, but due to Zig's lazy analysis we can still reference
    // it here.
    //
    // An example process is the `main` in `bidi_uucode.zig`
    const generated = @import("bidi_tables").Tables(BidiProperties);
    const Tables = lut.Tables(BidiProperties);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};
