const c = @import("c.zig");

pub fn init() !void {
    if (c.glslang_initialize_process() == 0) return error.GlslangInitFailed;
}

pub fn finalize() void {
    c.glslang_finalize_process();
}
