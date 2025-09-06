const builtin = @import("builtin");
const build_options = @import("build_options");

pub const c = @cImport({
    @cInclude("hb.h");
    if (build_options.freetype) @cInclude("hb-ft.h");
    if (build_options.coretext) @cInclude("hb-coretext.h");
});
