/// The visual style of the cursor. Whether or not it blinks
/// is determined by mode 12 (modes.zig). This mode is synchronized
/// with CSI q, the same as xterm.
pub const Style = enum {
    bar, // DECSCUSR 5, 6
    block, // DECSCUSR 1, 2
    underline, // DECSCUSR 3, 4

    /// The cursor styles below aren't known by DESCUSR and are custom
    /// implemented in Ghostty. They are reported as some standard style
    /// if requested, though.
    /// Hollow block cursor. This is a block cursor with the center empty.
    /// Reported as DECSCUSR 1 or 2 (block).
    block_hollow,

    /// Vintage cursor. A partial-height block that fills the cell from
    /// the bottom up. Height is controlled by cursor-style-vintage-height.
    /// Reported as DECSCUSR 3 or 4 (underline).
    vintage,
};
