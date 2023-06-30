const std = @import("std");

/// The state of a mouse button.
///
/// This is backed by a c_int so we can use this as-is for our embedding API.
///
/// IMPORTANT: Any changes here update include/ghostty.h
pub const MouseButtonState = enum(c_int) {
    release,
    press,
};

/// Possible mouse buttons. We only track up to 11 because thats the maximum
/// button input that terminal mouse tracking handles without becoming
/// ambiguous.
///
/// Its a bit silly to name numbers like this but given its a restricted
/// set, it feels better than passing around raw numeric literals.
///
/// This is backed by a c_int so we can use this as-is for our embedding API.
///
/// IMPORTANT: Any changes here update include/ghostty.h
pub const MouseButton = enum(c_int) {
    const Self = @This();

    /// The maximum value in this enum. This can be used to create a densely
    /// packed array, for example.
    pub const max = max: {
        var cur = 0;
        for (@typeInfo(Self).Enum.fields) |field| {
            if (field.value > cur) cur = field.value;
        }

        break :max cur;
    };

    unknown = 0,
    left = 1,
    right = 2,
    middle = 3,
    four = 4,
    five = 5,
    six = 6,
    seven = 7,
    eight = 8,
    nine = 9,
    ten = 10,
    eleven = 11,
};

/// The "momentum" of a mouse scroll event. This matches the macOS events
/// because it is the only reliable source right now of momentum events.
/// This is used to handle "intertial scrolling" (i.e. flicking).
///
/// https://developer.apple.com/documentation/appkit/nseventphase
pub const MouseMomentum = enum(u3) {
    none = 0,
    began = 1,
    stationary = 2,
    changed = 3,
    ended = 4,
    cancelled = 5,
    may_begin = 6,
};

/// The bitmask for mods for scroll events.
pub const ScrollMods = packed struct(u8) {
    /// True if this is a high-precision scroll event. For example, Apple
    /// devices such as Magic Mouse, trackpads, etc. are high-precision
    /// and send very detailed scroll events.
    precision: bool = false,

    /// The momentum phase (if available, supported) of the scroll event.
    /// This is used to handle "intertial scrolling" (i.e. flicking).
    momentum: MouseMomentum = .none,

    _padding: u4 = 0,

    // For our own understanding
    test {
        const testing = std.testing;
        try testing.expectEqual(@as(u8, @bitCast(ScrollMods{})), @as(u8, 0b0));
        try testing.expectEqual(
            @as(u8, @bitCast(ScrollMods{ .precision = true })),
            @as(u8, 0b0000_0001),
        );
    }
};
