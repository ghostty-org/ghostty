const build_options = @import("terminal_options");
const lib = @import("../lib/main.zig");
const lib_target: lib.Target = if (build_options.c_abi) .c else .zig;

/// C0 (7-bit) control characters from ANSI.
///
/// This is not complete, control characters are only added to this
/// as the terminal emulator handles them.
pub const C0 = enum(u7) {
    /// Null
    NUL = 0x00,
    /// Start of heading
    SOH = 0x01,
    /// Start of text
    STX = 0x02,
    /// Enquiry
    ENQ = 0x05,
    /// Bell
    BEL = 0x07,
    /// Backspace
    BS = 0x08,
    // Horizontal tab
    HT = 0x09,
    /// Line feed
    LF = 0x0A,
    /// Vertical Tab
    VT = 0x0B,
    /// Form feed
    FF = 0x0C,
    /// Carriage return
    CR = 0x0D,
    /// Shift out
    SO = 0x0E,
    /// Shift in
    SI = 0x0F,

    // Non-exhaustive so that @intToEnum never fails since the inputs are
    // user-generated.
    _,
};

/// The SGR rendition aspects that can be set, sometimes known as attributes.
/// The value corresponds to the parameter value for the SGR command (ESC [ m).
pub const RenditionAspect = enum(u16) {
    default = 0,
    bold = 1,
    default_fg = 39,
    default_bg = 49,

    // Non-exhaustive so that @intToEnum never fails since the inputs are
    // user-generated.
    _,
};

/// The device attribute request type (ESC [ c).
pub const DeviceAttributeReq = lib.Enum(
    lib_target,
    &.{
        "primary", // Blank
        "secondary", // >
        "tertiary", // =
    },
);

/// Possible cursor styles (ESC [ q)
pub const CursorStyle = lib.Enum(
    lib_target,
    &.{
        "default",
        "blinking_block",
        "steady_block",
        "blinking_underline",
        "steady_underline",
        "blinking_bar",
        "steady_bar",
    },
);

/// The status line type for DECSSDT.
pub const StatusLineType = enum(u16) {
    none = 0,
    indicator = 1,
    host_writable = 2,

    // Non-exhaustive so that @intToEnum never fails for unsupported values.
    _,
};

/// The display to target for status updates (DECSASD).
pub const StatusDisplay = lib.Enum(
    lib_target,
    &.{
        "main",
        "status_line",
    },
);

/// The possible modify key formats to ESC[>{a};{b}m
/// Note: this is not complete, we should add more as we support more
pub const ModifyKeyFormat = lib.Enum(
    lib_target,
    &.{
        "legacy",
        "cursor_keys",
        "function_keys",
        "other_keys_none",
        "other_keys_numeric_except",
        "other_keys_numeric",
    },
);

/// The protection modes that can be set for the terminal. See DECSCA and
/// ESC V, W.
pub const ProtectedMode = enum {
    off,
    iso, // ESC V, W
    dec, // CSI Ps " q
};
