const std = @import("std");
const builtin = @import("builtin");

/// Require a specific version of Zig to build this project.
pub fn requireZig(comptime required_zig: []const u8) void {
    // Fail compilation if the current Zig version doesn't meet requirements.
    const current_vsn = builtin.zig_version;
    const required_vsn = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (current_vsn.major != required_vsn.major or
        current_vsn.minor != required_vsn.minor)
    {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the required build version of v{}",
            .{ current_vsn, required_vsn },
        ));
    }
}
