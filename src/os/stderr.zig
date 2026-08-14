//! Raw, best-effort stderr writing that bypasses `std.Io` entirely.
//!
//! `std.debug.lockStderr` (and everything layered on top of it) routes
//! through `std.Options.debug_io`, whose default implementation is
//! `std.Io.Threaded`. This keeps ~70KB of unreachable code in binaries.

const std = @import("std");
const builtin = @import("builtin");

/// Write bytes to stderr using the most primitive mechanism available
/// for the target. This is best-effort: errors are ignored, since this
/// is only used for diagnostics (logging and panic messages).
///
/// Freestanding targets (e.g. wasm) have no stderr, so this is a no-op
/// there.
pub fn write(bytes: []const u8) void {
    switch (builtin.os.tag) {
        .freestanding, .other => {},

        .windows => {
            const windows = std.os.windows;
            const handle = windows.peb().ProcessParameters.hStdError;
            var iosb: windows.IO_STATUS_BLOCK = undefined;
            _ = windows.ntdll.NtWriteFile(
                handle,
                null, // event
                null, // APC routine
                null, // APC context
                &iosb,
                bytes.ptr,
                @intCast(bytes.len),
                null, // byte offset
                null, // key
            );
        },

        else => {
            const posix = std.posix;
            var i: usize = 0;
            while (i < bytes.len) {
                const rc = posix.system.write(
                    posix.STDERR_FILENO,
                    bytes[i..].ptr,
                    bytes.len - i,
                );
                switch (posix.errno(rc)) {
                    .SUCCESS => i += @as(usize, @intCast(rc)),
                    .INTR => continue,
                    else => return,
                }
            }
        },
    }
}

test write {
    // Smoke test: must not crash. We can't assert on the output without
    // capturing stderr, which isn't worth the complexity here.
    write("");
}
