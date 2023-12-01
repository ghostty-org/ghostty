const glslang = @import("main.zig");

var initialized: bool = false;

/// Call this function before any other tests in this package to ensure that
/// the glslang library is initialized.
pub fn ensureInit() !void {
    if (initialized) return;
    try glslang.init();
}
