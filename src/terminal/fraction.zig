//! Parsing of decimal fractions in the unit interval [0, 1].
//!
//! Escape sequences that carry fractional parameters (XTerm `rgbi:`
//! color specifications, glyph protocol padding) only ever need plain
//! decimal values such as "0.5". Using `std.fmt.parseFloat` for these
//! pulls the full correctly-rounded float parser and its lookup tables
//! into the binary (~26KB). This implements only the restricted subset
//! we need.
const std = @import("std");
const assert = std.debug.assert;

/// Parse a decimal fraction in the range [0, 1] inclusive.
///
/// Accepts an optional leading `+` or `-` sign followed by decimal
/// digits with an optional decimal point ("0.5", ".5", "1.", "1"); at
/// least one digit is required. Exponent and hexadecimal float syntax
/// are not supported. Returns null for invalid syntax and for any value
/// outside [0, 1] (so negative values other than -0 are rejected).
///
/// Results are correctly rounded for inputs of up to 15 fractional
/// digits; further digits are validated but ignored, which can move the
/// result by less than 1e-15.
pub fn parse(value: []const u8) ?f64 {
    var v = value;
    var negative = false;
    if (v.len > 0) switch (v[0]) {
        '+' => v = v[1..],
        '-' => {
            negative = true;
            v = v[1..];
        },
        else => {},
    };

    var i: usize = 0;
    const int_part: f64 = int_part: {
        var int_part: f64 = 0;
        while (i < v.len and v[i] != '.') : (i += 1) {
            const d = v[i];
            if (d < '0' or d > '9') return null;
            int_part = int_part * 10 + @as(f64, @floatFromInt(d - '0'));
        }
        break :int_part int_part;
    };

    var digits: usize = i;
    var frac: u64 = 0;
    var scale: u64 = 1;
    if (i < v.len) {
        assert(v[i] == '.');
        i += 1;
        while (i < v.len) : (i += 1) {
            const d = v[i];
            if (d < '0' or d > '9') return null;
            // Stop accumulating after 15 digits so that frac and scale
            // both stay exactly representable in f64 (and cannot
            // overflow), making the division below round only once.
            if (scale < 1_000_000_000_000_000) {
                frac = frac * 10 + (d - '0');
                scale *= 10;
            }
            digits += 1;
        }
    }
    if (digits == 0) return null;

    // frac and scale are both exact in f64 (below 2^53 and a power of
    // ten no greater than 1e15), so this division rounds only once.
    const magnitude = int_part +
        @as(f64, @floatFromInt(frac)) / @as(f64, @floatFromInt(scale));
    const result = if (negative) -magnitude else magnitude;

    // Range check. Written so that -0 passes and any out-of-range or
    // non-finite value fails.
    if (!(result >= 0 and result <= 1)) return null;
    return result;
}

test parse {
    const testing = std.testing;

    // Plain values
    try testing.expectEqual(0, parse("0").?);
    try testing.expectEqual(1, parse("1").?);
    try testing.expectEqual(0.5, parse("0.5").?);
    try testing.expectEqual(0.25, parse("0.25").?);
    try testing.expectEqual(1, parse("1.0").?);
    try testing.expectEqual(1, parse("1.000000").?);
    try testing.expectEqual(0, parse("0.0").?);

    // Partial forms
    try testing.expectEqual(0.5, parse(".5").?);
    try testing.expectEqual(1, parse("1.").?);
    try testing.expectEqual(0, parse("00.00").?);

    // Signs
    try testing.expectEqual(0.5, parse("+0.5").?);
    try testing.expectEqual(0, parse("-0").?);
    try testing.expectEqual(0, parse("-0.000").?);
    try testing.expectEqual(null, parse("-0.5"));
    try testing.expectEqual(null, parse("-1"));

    // Matches std.fmt.parseFloat rounding for typical inputs.
    try testing.expectEqual(
        std.fmt.parseFloat(f64, "0.3") catch unreachable,
        parse("0.3").?,
    );
    try testing.expectEqual(
        std.fmt.parseFloat(f64, "0.123456789012345") catch unreachable,
        parse("0.123456789012345").?,
    );

    // Digits past the 15th are ignored: long fractions stay finite and
    // equal their 15-digit truncation.
    try testing.expectEqual(
        parse("0.333333333333333").?,
        parse("0." ++ "3" ** 400).?,
    );

    // Out of range
    try testing.expectEqual(null, parse("1.0000001"));
    try testing.expectEqual(null, parse("2"));
    try testing.expectEqual(null, parse("255"));
    try testing.expectEqual(null, parse("1" ** 400));

    // Invalid syntax
    try testing.expectEqual(null, parse(""));
    try testing.expectEqual(null, parse("."));
    try testing.expectEqual(null, parse("+"));
    try testing.expectEqual(null, parse("-"));
    try testing.expectEqual(null, parse("+."));
    try testing.expectEqual(null, parse("abc"));
    try testing.expectEqual(null, parse("0.5x"));
    try testing.expectEqual(null, parse("0x0.8"));
    try testing.expectEqual(null, parse("0..5"));
    try testing.expectEqual(null, parse("0.5.5"));
    try testing.expectEqual(null, parse(" 0.5"));
    try testing.expectEqual(null, parse("0.5 "));
    try testing.expectEqual(null, parse("1e-1"));
    try testing.expectEqual(null, parse("nan"));
    try testing.expectEqual(null, parse("inf"));
}
