const init = @import("init.zig");
const Encoding = @import("types.zig").Encoding;

var initialized: bool = false;

/// Call this function before any other tests in this package to ensure that
/// the oni library is initialized. This should only be used for tests
/// and only when you're sure this is the ONLY way that oni is being
/// initialized.
///
/// This always only initializes the encodings the tests use.
pub fn ensureInit() !void {
    if (initialized) return;
    try init.init(&.{Encoding.utf8});
}
