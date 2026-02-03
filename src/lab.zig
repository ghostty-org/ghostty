const terminal = @import("./terminal/main.zig");
const std = @import("std");

pub const Lab = struct {
    l: f32,
    a: f32,
    b: f32,

    pub fn fromTerminalRgb(rgb: terminal.color.RGB) Lab {
        var r: f32 = @as(f32, @floatFromInt(rgb.r)) / 255.0;
        var g: f32 = @as(f32, @floatFromInt(rgb.g)) / 255.0;
        var b: f32 = @as(f32, @floatFromInt(rgb.b)) / 255.0;

        r = if (r > 0.04045) std.math.pow(f32, (r + 0.055) / 1.055, 2.4) else r / 12.92;
        g = if (g > 0.04045) std.math.pow(f32, (g + 0.055) / 1.055, 2.4) else g / 12.92;
        b = if (b > 0.04045) std.math.pow(f32, (b + 0.055) / 1.055, 2.4) else b / 12.92;

        var x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047;
        var y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750;
        var z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883;

        x = if (x > 0.008856) std.math.cbrt(x) else 7.787 * x + 16.0 / 116.0;
        y = if (y > 0.008856) std.math.cbrt(y) else 7.787 * y + 16.0 / 116.0;
        z = if (z > 0.008856) std.math.cbrt(z) else 7.787 * z + 16.0 / 116.0;

        return .{ .l = 116.0 * y - 16.0, .a = 500.0 * (x - y), .b = 200.0 * (y - z) };
    }

    pub fn toTerminalRgb(self: Lab) terminal.color.RGB {
        const y = (self.l + 16.0) / 116.0;
        const x = self.a / 500.0 + y;
        const z = y - self.b / 200.0;

        const x3 = x * x * x;
        const y3 = y * y * y;
        const z3 = z * z * z;
        const xf = (if (x3 > 0.008856) x3 else (x - 16.0 / 116.0) / 7.787) * 0.95047;
        const yf = if (y3 > 0.008856) y3 else (y - 16.0 / 116.0) / 7.787;
        const zf = (if (z3 > 0.008856) z3 else (z - 16.0 / 116.0) / 7.787) * 1.08883;

        var r = xf * 3.2404542 - yf * 1.5371385 - zf * 0.4985314;
        var g = -xf * 0.9692660 + yf * 1.8760108 + zf * 0.0415560;
        var b = xf * 0.0556434 - yf * 0.2040259 + zf * 1.0572252;

        r = if (r > 0.0031308) 1.055 * std.math.pow(f32, r, 1.0 / 2.4) - 0.055 else 12.92 * r;
        g = if (g > 0.0031308) 1.055 * std.math.pow(f32, g, 1.0 / 2.4) - 0.055 else 12.92 * g;
        b = if (b > 0.0031308) 1.055 * std.math.pow(f32, b, 1.0 / 2.4) - 0.055 else 12.92 * b;

        return .{
            .r = @intFromFloat(@min(@max(r, 0.0), 1.0) * 255.0 + 0.5),
            .g = @intFromFloat(@min(@max(g, 0.0), 1.0) * 255.0 + 0.5),
            .b = @intFromFloat(@min(@max(b, 0.0), 1.0) * 255.0 + 0.5),
        };
    }

    pub fn lerp(t: f32, a: Lab, b: Lab) Lab {
        return .{
            .l = a.l + t * (b.l - a.l),
            .a = a.a + t * (b.a - a.a),
            .b = a.b + t * (b.b - a.b)
        };
    }
};




