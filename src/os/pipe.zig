const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const posix = std.posix;
const compat_fd = @import("../lib/compat/fd.zig");

/// pipe() that works on Windows and POSIX. For POSIX systems, this sets
/// CLOEXEC on the file descriptors.
pub fn pipe() ![2]posix.fd_t {
    switch (builtin.os.tag) {
        else => return compat_fd.pipe2(.{ .CLOEXEC = true }),
        .windows => {
            var read: windows.HANDLE = undefined;
            var write: windows.HANDLE = undefined;
            if (windows.exp.kernel32.CreatePipe(&read, &write, null, 0) == windows.FALSE) {
                return windows.unexpectedError(windows.GetLastError());
            }

            return .{ read, write };
        },
    }
}
