const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

pub const ColorSpace = opaque {
    pub fn createDeviceGray() Allocator.Error!*ColorSpace {
        return @as(
            ?*ColorSpace,
            @ptrFromInt(@intFromPtr(c.CGColorSpaceCreateDeviceGray())),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createDeviceRGB() Allocator.Error!*ColorSpace {
        return @as(
            ?*ColorSpace,
            @ptrFromInt(@intFromPtr(c.CGColorSpaceCreateDeviceRGB())),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createNamed(name: Name) Allocator.Error!*ColorSpace {
        return @as(
            ?*ColorSpace,
            @ptrFromInt(@intFromPtr(c.CGColorSpaceCreateWithName(name.cfstring()))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *ColorSpace) void {
        c.CGColorSpaceRelease(@ptrCast(self));
    }

    pub const Name = enum {
        /// This color space uses the DCI P3 primaries, a D65 white point, and
        /// the sRGB transfer function.
        displayP3,
        /// The Display P3 color space with a linear transfer function and
        /// extended-range values.
        extendedLinearDisplayP3,
        /// The sRGB colorimetry and non-linear transfer function are specified
        /// in IEC 61966-2-1.
        sRGB,
        /// This color space has the same colorimetry as `sRGB`, but uses a
        /// linear transfer function.
        linearSRGB,
        /// This color space has the same colorimetry as `sRGB`, but you can
        /// encode component values below `0.0` and above `1.0`. Negative values
        /// are encoded as the signed reflection of the original encoding
        /// function, as shown in the formula below:
        /// ```
        /// extendedTransferFunction(x) = sign(x) * sRGBTransferFunction(abs(x))
        /// ```
        extendedSRGB,
        /// This color space has the same colorimetry as `sRGB`; in addition,
        /// you may encode component values below `0.0` and above `1.0`.
        extendedLinearSRGB,
        /// ...
        genericGrayGamma2_2,
        /// ...
        linearGray,
        /// This color space has the same colorimetry as `genericGrayGamma2_2`,
        /// but you can encode component values below `0.0` and above `1.0`.
        /// Negative values are encoded as the signed reflection of the
        /// original encoding function, as shown in the formula below:
        /// ```
        /// extendedGrayTransferFunction(x) = sign(x) * gamma22Function(abs(x))
        /// ```
        extendedGray,
        /// This color space has the same colorimetry as `linearGray`; in
        /// addition, you may encode component values below `0.0` and above `1.0`.
        extendedLinearGray,

        fn cfstring(self: Name) c.CFStringRef {
            return switch (self) {
                .displayP3 => c.kCGColorSpaceDisplayP3,
                .extendedLinearDisplayP3 => c.kCGColorSpaceExtendedLinearDisplayP3,
                .sRGB => c.kCGColorSpaceSRGB,
                .extendedSRGB => c.kCGColorSpaceExtendedSRGB,
                .linearSRGB => c.kCGColorSpaceLinearSRGB,
                .extendedLinearSRGB => c.kCGColorSpaceExtendedLinearSRGB,
                .genericGrayGamma2_2 => c.kCGColorSpaceGenericGrayGamma2_2,
                .extendedGray => c.kCGColorSpaceExtendedGray,
                .linearGray => c.kCGColorSpaceLinearGray,
                .extendedLinearGray => c.kCGColorSpaceExtendedLinearGray,
            };
        }
    };
};

test {
    //const testing = std.testing;

    const space = try ColorSpace.createDeviceGray();
    defer space.release();
}

test {
    const space = try ColorSpace.createDeviceRGB();
    defer space.release();
}
