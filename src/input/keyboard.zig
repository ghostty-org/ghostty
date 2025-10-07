const std = @import("std");
const OptionAsAlt = @import("config.zig").OptionAsAlt;

/// Keyboard layouts.
///
/// These aren't heavily used in Ghostty and having a fully comprehensive
/// list is not important. We only need to distinguish between a few
/// different layouts for some nice-to-have features, such as setting a default
/// value for "macos-option-as-alt".
pub const Layout = enum {
    // Unknown, unmapped layout. Ghostty should not make any assumptions
    // about the layout of the keyboard.
    unknown,

    // The remaining should be fairly self-explanatory:
    us_standard,
    us_international,

    /// Map an Apple keyboard layout ID to a value in this enum. The layout
    /// ID can be retrieved using Carbon's TIKeyboardLayoutGetInputSourceProperty
    /// function.
    ///
    /// Even though our layout supports "unknown", we return null if we don't
    /// recognize the layout ID so callers can detect this scenario.
    pub fn mapAppleId(id: []const u8) ?Layout {
        if (std.mem.eql(u8, id, "com.apple.keylayout.US")) {
            return .us_standard;
        } else if (std.mem.eql(u8, id, "com.apple.keylayout.USInternational")) {
            return .us_international;
        }

        return null;
    }

    /// Returns the default macos-option-as-alt value for this layout.
    ///
    /// We apply some heuristics to change the default based on the keyboard
    /// layout if "macos-option-as-alt" is unset. We do this because on some
    /// keyboard layouts such as US standard layouts, users generally expect
    /// an input such as option-b to map to alt-b but macOS by default will
    /// convert it to the codepoint "∫".
    ///
    /// This behavior however is desired on international layout where the
    /// option key is used for important, regularly used inputs.
    pub fn detectOptionAsAlt(self: Layout) OptionAsAlt {
        return switch (self) {
            // On US standard, the option key is typically used as alt
            // and not as a modifier for other codepoints. For example,
            // option-B = ∫ but usually the user wants alt-B.
            .us_standard,
            .us_international,
            => .true,

            .unknown,
            => .false,
        };
    }
};
