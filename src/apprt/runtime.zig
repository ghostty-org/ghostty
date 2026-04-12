const std = @import("std");

/// Runtime is the runtime to use for Ghostty. All runtimes do not provide
/// equivalent feature sets.
pub const Runtime = enum {
    /// Will not produce an executable at all when `zig build` is called.
    /// This is only useful for non-app/library-only builds.
    none,

    /// Native Win32 runtime for the Windows-only fork.
    win32,

    pub fn default(target: std.Target) Runtime {
        return switch (target.os.tag) {
            .windows => .win32,
            else => .none,
        };
    }
};

test {
    _ = Runtime;
}
