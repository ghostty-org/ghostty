//! Shared color conversion used by Metal and OpenGL `loadColor`.

const std = @import("std");

/// sRGB transfer inverse. Same split as the Metal shader.
pub fn linearize(v: f32) f32 {
    return if (v <= 0.04045)
        v / 12.92
    else
        std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// sRGB transfer. Same split as the Metal shader.
pub fn unlinearize(v: f32) f32 {
    return if (v <= 0.0031308)
        v * 12.92
    else
        std.math.pow(f32, v, 1.0 / 2.4) * 1.055 - 0.055;
}

/// Linear sRGB to linear Display P3. Same matrix as the Metal shader.
pub fn srgbToDisplayP3(srgb: [3]f32) [3]f32 {
    return mulMatVec(sRGB_DP3, srgb);
}

// D50-adapted sRGB to XYZ.
// http://www.brucelindbloom.com/Eqn_RGB_XYZ_Matrix.html
const sRGB_XYZ: [3][3]f32 = .{
    .{ 0.4360747, 0.3850649, 0.1430804 },
    .{ 0.2225045, 0.7168786, 0.0606169 },
    .{ 0.0139322, 0.0971045, 0.7141733 },
};

// XYZ to Display P3.
// http://endavid.com/index.php?entry=79
const XYZ_DP3: [3][3]f32 = .{
    .{ 2.40414768, -0.99010704, -0.39759019 },
    .{ -0.84239098, 1.79905954, 0.01597023 },
    .{ 0.04838763, -0.09752546, 1.27393636 },
};

// Metal: sRGB_DP3 = XYZ_DP3 * sRGB_XYZ after transposing each factor.
const sRGB_DP3: [3][3]f32 = mulMat(XYZ_DP3, sRGB_XYZ);

fn mulMat(a: [3][3]f32, b: [3][3]f32) [3][3]f32 {
    var out: [3][3]f32 = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            out[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
        }
    }
    return out;
}

fn mulMatVec(m: [3][3]f32, v: [3]f32) [3]f32 {
    return .{
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    };
}

test "srgbToDisplayP3 linear red is first matrix column" {
    const testing = std.testing;
    const got = srgbToDisplayP3(.{ 1, 0, 0 });
    try testing.expectApproxEqAbs(0.8225454, got[0], 1e-5);
    try testing.expectApproxEqAbs(0.03317595, got[1], 1e-5);
    try testing.expectApproxEqAbs(0.01714950, got[2], 1e-5);
}
