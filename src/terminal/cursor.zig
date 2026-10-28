const lib = @import("../lib/main.zig");

/// The visual style of the cursor. Whether or not it blinks
/// is determined by mode 12 (modes.zig). This mode is synchronized
/// with CSI q, the same as xterm.
///
/// Bar, block, and underline correspond to DECSCUSR 5/6, 1/2, and 3/4.
/// Hollow block is Ghostty-specific and is reported as DECSCUSR 1 or 2.
pub const Style = lib.Enum(.zig, &.{
    // DECSCUSR 5, 6
    "bar",

    // DECSCUSR 1, 2
    "block",

    // DECSCUSR 3, 4
    "underline",

    // The cursor styles below aren't known by DESCUSR and are custom
    // implemented in Ghostty. They are reported as some standard style
    // if requested, though.
    // Hollow block cursor. This is a block cursor with the center empty.
    // Reported as DECSCUSR 1 or 2 (block).
    "block_hollow",
});
