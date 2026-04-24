const std = @import("std");

export fn simdutf_memcpy(noalias dest: ?[*]u8, noalias src: ?[*]const u8, n: usize) ?[*]u8 {
    const d = dest orelse return dest;
    const s = src orelse return dest;
    @memcpy(d[0..n], s[0..n]);
    return dest;
}

export fn simdutf_memmove(dest: ?[*]u8, src: ?[*]const u8, n: usize) ?[*]u8 {
    const d = dest orelse return dest;
    const s = src orelse return dest;
    const dst_slice = d[0..n];
    const src_slice = s[0..n];
    if (@intFromPtr(d) <= @intFromPtr(s)) {
        @memcpy(dst_slice, src_slice);
    } else {
        std.mem.copyBackwards(u8, dst_slice, src_slice);
    }
    return dest;
}

export fn simdutf_memset(dest: ?[*]u8, c: c_int, n: usize) ?[*]u8 {
    const d = dest orelse return dest;
    @memset(d[0..n], @as(u8, @intCast(c & 0xff)));
    return dest;
}

export fn simdutf_memcmp(lhs: ?[*]const u8, rhs: ?[*]const u8, n: usize) c_int {
    const l = lhs orelse return 0;
    const r = rhs orelse return 0;
    const order = std.mem.order(u8, l[0..n], r[0..n]);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

export fn simdutf_strlen(s: ?[*:0]const u8) usize {
    const str = s orelse return 0;
    return std.mem.len(str);
}

export fn simdutf_getenv(_: ?[*:0]const u8) ?[*:0]const u8 {
    return null;
}
