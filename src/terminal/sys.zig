//! System interface for the terminal package.
//!
//! This provides runtime-swappable function pointers for operations that
//! depend on external implementations (e.g. image decoding). Each function
//! pointer is initialized with a default implementation if available.
//!
//! This exists so that the terminal package doesn't have hard dependencies
//! on specific libraries and enables embedders of the terminal package to
//! swap out implementations as needed at startup to provide their own
//! implementations.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("terminal_options");

/// Decode PNG data into RGBA pixels. If null, PNG decoding is unsupported
/// and the exact semantics are up to callers. For example, the Kitty Graphics
/// Protocol will work but cannot accept PNG images.
pub var decode_png: ?DecodePngFn = png: {
    if (build_options.artifact == .lib) break :png null;
    break :png &decodePngWuffs;
};

pub const DecodeError = Allocator.Error || error{InvalidData};
pub const DecodePngFn = *const fn (Allocator, []const u8) DecodeError!Image;

/// The result of decoding an image. The caller owns the returned data
/// and must free it with the same allocator that was passed to the
/// decode function.
pub const Image = struct {
    width: u32,
    height: u32,
    data: []u8,
};

fn decodePngWuffs(
    alloc: Allocator,
    data: []const u8,
) DecodeError!Image {
    const wuffs = @import("wuffs");
    const result = wuffs.png.decode(
        alloc,
        data,
    ) catch |err| switch (err) {
        error.WuffsError => return error.InvalidData,
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.InvalidData,
    };

    return .{
        .width = result.width,
        .height = result.height,
        .data = result.data,
    };
}

/// Fill a buffer with cryptographically secure random bytes. If null,
/// the terminal's `std.Io` (`randomSecure`) is used. This is an override
/// for embedders whose Io has no entropy source (e.g. wasm32-freestanding,
/// where TinyIo degrades to `std.Io.failing`) or that want to control
/// the source; when set it is used on every target.
///
/// This is used for secrets, so it must be a real CSPRNG. An error
/// makes the operation that needed the entropy fail; nothing falls back
/// to weaker randomness.
pub var random_secure: ?RandomSecureFn = null;

pub const RandomSecureError = error{EntropyUnavailable};
pub const RandomSecureFn = *const fn ([]u8) RandomSecureError!void;

/// Fill `buffer` with secure random bytes from `random_secure` if set,
/// otherwise from `io`. Every use of secure entropy in the terminal
/// package goes through this so the override applies uniformly.
pub fn randomSecure(io: std.Io, buffer: []u8) std.Io.RandomSecureError!void {
    if (random_secure) |func| return func(buffer);
    return io.randomSecure(buffer);
}

test "randomSecure: override is preferred over the Io" {
    const testing = std.testing;
    const S = struct {
        fn fill(buffer: []u8) RandomSecureError!void {
            @memset(buffer, 0xAB);
        }
        fn fail(_: []u8) RandomSecureError!void {
            return error.EntropyUnavailable;
        }
    };

    // Without the override a failing Io fails.
    var buf: [8]u8 = @splat(0);
    try testing.expectError(error.EntropyUnavailable, randomSecure(std.Io.failing, &buf));

    // With it, the Io is never consulted.
    random_secure = &S.fill;
    defer random_secure = null;
    try randomSecure(std.Io.failing, &buf);
    try testing.expect(std.mem.allEqual(u8, &buf, 0xAB));

    // An override failure surfaces as the Io's error.
    random_secure = &S.fail;
    try testing.expectError(error.EntropyUnavailable, randomSecure(testing.io, &buf));
}
