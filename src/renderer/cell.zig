const ziglyph = @import("ziglyph");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");

pub const FgMode = enum {
    /// Normal non-colored text rendering. The text can leave the cell
    /// size if it is larger than the cell to allow for ligatures.
    normal,

    /// Colored text rendering, specifically Emoji.
    color,

    /// Similar to normal but the text must be constrained to the cell
    /// size. If a glyph is larger than the cell then it must be resized
    /// to fit.
    constrained,
};

/// Returns the appropriate foreground mode for the given cell. This is
/// meant to be called from the typical updateCell function within a
/// renderer.
pub fn fgMode(
    group: *font.Group,
    screen: *terminal.Screen,
    cell: terminal.Screen.Cell,
    shaper_run: font.shape.TextRun,
    x: usize,
    y: usize,
) !FgMode {
    const presentation = try group.presentationFromIndex(shaper_run.font_index);
    return switch (presentation) {
        // Emoji is always full size and color.
        .emoji => .color,

        // If it is text it is slightly more complex. If we are a codepoint
        // in the private use area and we are at the end or the next cell
        // is not empty, we need to constrain rendering.
        //
        // We do this specifically so that Nerd Fonts can render their
        // icons without overlapping with subsequent characters. But if
        // the subsequent character is empty, then we allow it to use
        // the full glyph size. See #1071.
        .text => text: {
            if (!ziglyph.general_category.isPrivateUse(@intCast(cell.char))) {
                break :text .normal;
            }

            // We exempt the Powerline single-character range from this since
            // they exhibit box-drawing behavior and should not be constrained.
            if (isPowerlineSingle(cell.char)) {
                break :text .normal;
            }

            // If we are at the end of the screen its definitely constrained
            if (x == screen.cols - 1) break :text .constrained;

            // If we have a previous cell and it was PUA then we need to
            // also constrain. This is so that multiple PUA glyphs align.
            if (x > 0) {
                const prev_cell = screen.getCell(.active, y, x - 1);
                if (ziglyph.general_category.isPrivateUse(@intCast(prev_cell.char))) {
                    break :text .constrained;
                }
            }

            // If the next cell is empty, then we allow it to use the
            // full glyph size.
            const next_cell = screen.getCell(.active, y, x + 1);
            if (next_cell.char == 0 or next_cell.char == ' ') {
                break :text .normal;
            }

            // Must be constrained
            break :text .constrained;
        },
    };
}

// Returns true if the codepoint is a part of the Powerline range and is
// single-cell.
fn isPowerlineSingle(char: u32) bool {
    return switch (char) {
        0xE0B0...0xE0BF, 0xE0D2, 0xE0D4 => true,
        else => false,
    };
}
