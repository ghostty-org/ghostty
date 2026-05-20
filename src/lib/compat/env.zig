//! Code taken from 0.15.2 `std.posix` and `std.process`. See README.md for
//! license and details.
const builtin = @import("builtin");
const std = @import("std");

const native_os = builtin.os.tag;
const posix = std.posix;
const windows = std.os.windows;
const unicode = std.unicode;

/// The OS environment. Should be populated through main() and possibly other
/// startup code, designed to mimic legacy std.os.environ. Only used when not
/// linking libc on POSIX.
///
/// Note that this has some limitations, namely that it may not necessarily
/// reflect the process environment should the process environment be changed
/// mid-flight.
pub var os_environ: ?[]const [*:0]const u8 = null;

pub const GetEnvMapError = error{
    OutOfMemory,
    /// WASI-only. `environ_sizes_get` or `environ_get`
    /// failed for an unexpected reason.
    Unexpected,
};

/// Returns a snapshot of the environment variables of the current process. Any
/// modifications to the resulting `Environ.Map` will not be reflected in the
/// environment, and likewise, any future modifications to the environment will
/// not be reflected in the `Environ.Map`. Caller owns resulting `Environ.Map`
/// and should call its `deinit` fn when done.
pub fn getEnvMap(allocator: std.mem.Allocator) GetEnvMapError!std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();

    if (native_os == .windows) {
        const ptr = windows.peb().ProcessParameters.Environment;

        var i: usize = 0;
        while (ptr[i] != 0) {
            const key_start = i;

            // There are some special environment variables that start with =,
            // so we need a special case to not treat = as a key/value separator
            // if it's the first character.
            // https://devblogs.microsoft.com/oldnewthing/20100506-00/?p=14133
            if (ptr[key_start] == '=') i += 1;

            while (ptr[i] != 0 and ptr[i] != '=') : (i += 1) {}
            const key_w = ptr[key_start..i];
            const key = try unicode.wtf16LeToWtf8Alloc(allocator, key_w);
            errdefer allocator.free(key);

            if (ptr[i] == '=') i += 1;

            const value_start = i;
            while (ptr[i] != 0) : (i += 1) {}
            const value_w = ptr[value_start..i];
            const value = try unicode.wtf16LeToWtf8Alloc(allocator, value_w);
            errdefer allocator.free(value);

            i += 1; // skip over null byte

            try result.putMove(key, value);
        }
        return result;
    } else if (native_os == .wasi and !builtin.link_libc) {
        var environ_count: usize = undefined;
        var environ_buf_size: usize = undefined;

        const environ_sizes_get_ret = std.os.wasi.environ_sizes_get(&environ_count, &environ_buf_size);
        if (environ_sizes_get_ret != .SUCCESS) {
            return posix.unexpectedErrno(environ_sizes_get_ret);
        }

        if (environ_count == 0) {
            return result;
        }

        const environ = try allocator.alloc([*:0]u8, environ_count);
        defer allocator.free(environ);
        const environ_buf = try allocator.alloc(u8, environ_buf_size);
        defer allocator.free(environ_buf);

        const environ_get_ret = std.os.wasi.environ_get(environ.ptr, environ_buf.ptr);
        if (environ_get_ret != .SUCCESS) {
            return posix.unexpectedErrno(environ_get_ret);
        }

        for (environ) |env| {
            const pair = std.mem.sliceTo(env, 0);
            var parts = std.mem.splitScalar(u8, pair, '=');
            const key = parts.first();
            const value = parts.rest();
            try result.put(key, value);
        }
        return result;
    } else if (builtin.link_libc) {
        var ptr = std.c.environ;
        while (ptr[0]) |line| : (ptr += 1) {
            var line_i: usize = 0;
            while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
            const key = line[0..line_i];

            var end_i: usize = line_i;
            while (line[end_i] != 0) : (end_i += 1) {}
            const value = line[line_i + 1 .. end_i];

            try result.put(key, value);
        }
        return result;
    } else {
        if (os_environ) |environ| {
            for (environ) |line| {
                var line_i: usize = 0;
                while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
                const key = line[0..line_i];

                var end_i: usize = line_i;
                while (line[end_i] != 0) : (end_i += 1) {}
                const value = line[line_i + 1 .. end_i];

                try result.put(key, value);
            }
        }
        return result;
    }
}

test "getEnvMap" {
    var env = try getEnvMap(std.testing.allocator);
    defer env.deinit();
}

pub const GetEnvVarOwnedError = error{
    OutOfMemory,
    EnvironmentVariableNotFound,

    /// On Windows, environment variable keys provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,
};

/// Caller must free returned memory.
/// On Windows, if `key` is not valid [WTF-8](https://simonsapin.github.io/wtf-8/),
/// then `error.InvalidWtf8` is returned.
/// On Windows, the value is encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On other platforms, the value is an opaque sequence of bytes with no particular encoding.
pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) GetEnvVarOwnedError![]u8 {
    if (native_os == .windows) {
        const result_w = blk: {
            var stack_alloc = std.heap.stackFallback(256 * @sizeOf(u16), allocator);
            const stack_allocator = stack_alloc.get();
            const key_w = try unicode.wtf8ToWtf16LeAllocZ(stack_allocator, key);
            defer stack_allocator.free(key_w);

            break :blk getenvW(key_w) orelse return error.EnvironmentVariableNotFound;
        };
        // wtf16LeToWtf8Alloc can only fail with OutOfMemory
        return unicode.wtf16LeToWtf8Alloc(allocator, result_w);
    } else if (native_os == .wasi and !builtin.link_libc) {
        var envmap = getEnvMap(allocator) catch return error.OutOfMemory;
        defer envmap.deinit();
        const val = envmap.get(key) orelse return error.EnvironmentVariableNotFound;
        return allocator.dupe(u8, val);
    } else {
        const result = getenv(key) orelse return error.EnvironmentVariableNotFound;
        return allocator.dupe(u8, result);
    }
}

test "getEnvVarOwned" {
    try std.testing.expectError(
        error.EnvironmentVariableNotFound,
        getEnvVarOwned(std.testing.allocator, "BADENV"),
    );
}

/// Get an environment variable.
/// See also `getenvZ`.
pub fn getenv(key: []const u8) ?[:0]const u8 {
    if (native_os == .windows) {
        @compileError("std.posix.getenv is unavailable for Windows because environment strings are in WTF-16 format. See std.process.getEnvVarOwned for a cross-platform API or std.process.getenvW for a Windows-specific API.");
    }
    if (std.mem.indexOfScalar(u8, key, '=') != null) {
        return null;
    }
    if (builtin.link_libc) {
        var ptr = std.c.environ;
        while (ptr[0]) |line| : (ptr += 1) {
            var line_i: usize = 0;
            while (line[line_i] != 0) : (line_i += 1) {
                if (line_i == key.len) break;
                if (line[line_i] != key[line_i]) break;
            }
            if ((line_i != key.len) or (line[line_i] != '=')) continue;

            return std.mem.sliceTo(line + line_i + 1, 0);
        }
        return null;
    }
    if (native_os == .wasi) {
        @compileError("std.posix.getenv is unavailable for WASI. See std.process.getEnvMap or std.process.getEnvVarOwned for a cross-platform API.");
    }
    if (os_environ) |environ| {
        for (environ) |ptr| {
            var line_i: usize = 0;
            while (ptr[line_i] != 0) : (line_i += 1) {
                if (line_i == key.len) break;
                if (ptr[line_i] != key[line_i]) break;
            }
            if ((line_i != key.len) or (ptr[line_i] != '=')) continue;

            return std.mem.sliceTo(ptr + line_i + 1, 0);
        }
    }
    return null;
}

/// Windows-only. Get an environment variable with a null-terminated, WTF-16 encoded name.
///
/// This function performs a Unicode-aware case-insensitive lookup using RtlEqualUnicodeString.
///
/// See also:
/// * `std.posix.getenv`
/// * `getEnvMap`
/// * `getEnvVarOwned`
/// * `hasEnvVarConstant`
/// * `hasEnvVar`
pub fn getenvW(key: [*:0]const u16) ?[:0]const u16 {
    if (native_os != .windows) {
        @compileError("Windows-only");
    }
    const key_slice = std.mem.sliceTo(key, 0);
    // '=' anywhere but the start makes this an invalid environment variable name
    if (key_slice.len > 0 and std.mem.indexOfScalar(u16, key_slice[1..], '=') != null) {
        return null;
    }
    const ptr = windows.peb().ProcessParameters.Environment;
    var i: usize = 0;
    while (ptr[i] != 0) {
        const key_value = std.mem.sliceTo(ptr[i..], 0);

        // There are some special environment variables that start with =,
        // so we need a special case to not treat = as a key/value separator
        // if it's the first character.
        // https://devblogs.microsoft.com/oldnewthing/20100506-00/?p=14133
        const equal_search_start: usize = if (key_value[0] == '=') 1 else 0;
        const equal_index = std.mem.indexOfScalarPos(u16, key_value, equal_search_start, '=') orelse {
            // This is enforced by CreateProcess.
            // If violated, CreateProcess will fail with INVALID_PARAMETER.
            unreachable; // must contain a =
        };

        const this_key = key_value[0..equal_index];
        if (windows.eqlIgnoreCaseWTF16(key_slice, this_key)) {
            return key_value[equal_index + 1 ..];
        }

        // skip past the NUL terminator
        i += key_value.len + 1;
    }
    return null;
}

/// Get an environment variable with a null-terminated name.
/// See also `getenv`.
pub fn getenvZ(key: [*:0]const u8) ?[:0]const u8 {
    if (builtin.link_libc) {
        const value = std.c.getenv(key) orelse return null;
        return std.mem.sliceTo(value, 0);
    }
    if (native_os == .windows) {
        @compileError("std.posix.getenvZ is unavailable for Windows because environment string is in WTF-16 format. See std.process.getEnvVarOwned for cross-platform API or std.process.getenvW for Windows-specific API.");
    }
    return getenv(std.mem.sliceTo(key, 0));
}
