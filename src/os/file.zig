const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.os);

/// This maximizes the number of file descriptors we can have open. We
/// need to do this because each window consumes at least a handful of fds.
/// This is extracted from the Zig compiler source code.
/// Return zero if there's an error, otherwise returns the old softlimit.
pub fn fixMaxFiles() u64 {
    if (!@hasDecl(posix.system, "rlimit")) return 0;

    var lim = posix.getrlimit(.NOFILE) catch {
        log.warn("failed to query file handle limit, may limit max windows", .{});
        return 0; // Oh well; we tried.
    };

    const presoft = lim.cur;

    // If we're already at the max, we're done.
    if (lim.cur >= lim.max) {
        log.debug("file handle limit already maximized value={}", .{lim.cur});
        return presoft;
    }

    // Do a binary search for the limit.
    var min: posix.rlim_t = lim.cur;
    var max: posix.rlim_t = 1 << 20;
    // But if there's a defined upper bound, don't search, just set it.
    if (lim.max != posix.RLIM.INFINITY) {
        min = lim.max;
        max = lim.max;
    }

    while (true) {
        lim.cur = min + @divTrunc(max - min, 2); // on freebsd rlim_t is signed
        if (posix.setrlimit(.NOFILE, lim)) |_| {
            min = lim.cur;
        } else |_| {
            max = lim.cur;
        }
        if (min + 1 >= max) break;
    }

    log.debug("file handle limit raised value={}", .{lim.cur});
    return presoft;
}

/// Return the recommended path for temporary files.
/// This may not actually allocate memory, use freeTmpDir to properly
/// free the memory when applicable.
pub fn allocTmpDir(allocator: std.mem.Allocator) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // TODO: what is a good fallback path on windows?
        const v = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("TMP")) orelse return null;
        return std.unicode.utf16leToUtf8Alloc(allocator, v) catch |e| {
            log.warn("failed to convert temp dir path from windows string: {}", .{e});
            return null;
        };
    }
    if (posix.getenv("TMPDIR")) |v| return v;
    if (posix.getenv("TMP")) |v| return v;
    return "/tmp";
}

/// Free a path returned by tmpDir if it allocated memory.
/// This is a "no-op" for all platforms except windows.
pub fn freeTmpDir(allocator: std.mem.Allocator, dir: []const u8) void {
    if (builtin.os.tag == .windows) {
        allocator.free(dir);
    }
}
