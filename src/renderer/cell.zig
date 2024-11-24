const ziglyph = @import("ziglyph");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");

/// Returns true if a codepoint for a cell is a covering character. A covering
/// character is a character that covers the entire cell. This is used to
/// make window-padding-color=extend work better. See #2099.
pub fn isCovering(cp: u21) bool {
    return switch (cp) {
        // U+2588 FULL BLOCK
        0x2588 => true,

        else => false,
    };
}

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

    /// Similar to normal, but the text consists of Powerline glyphs and is
    /// optionally exempt from padding color extension and minimum contrast requirements.
    powerline,
};

/// Returns the appropriate foreground mode for the given cell. This is
/// meant to be called from the typical updateCell function within a
/// renderer.
pub fn fgMode(
    presentation: font.Presentation,
    cell_pin: terminal.Pin,
) !FgMode {
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
            const cell = cell_pin.rowAndCell().cell;
            const cp = cell.codepoint();

            if (!ziglyph.general_category.isPrivateUse(cp) and
                !ziglyph.blocks.isDingbats(cp))
            {
                break :text .normal;
            }

            // Special-case Powerline glyphs. They exhibit box drawing behavior
            // and should not be constrained. They have their own special category
            // though because they're used for other logic (i.e. disabling
            // min contrast).
            if (isPowerline(cp)) {
                break :text .powerline;
            }

            // If we are at the end of the screen its definitely constrained
            if (cell_pin.x == cell_pin.node.data.size.cols - 1) break :text .constrained;

            // If we have a previous cell and it was PUA then we need to
            // also constrain. This is so that multiple PUA glyphs align.
            // As an exception, we ignore powerline glyphs since they are
            // used for box drawing and we consider them whitespace.
            if (cell_pin.x > 0) prev: {
                const prev_cp = prev_cp: {
                    var copy = cell_pin;
                    copy.x -= 1;
                    const prev_cell = copy.rowAndCell().cell;
                    break :prev_cp prev_cell.codepoint();
                };

                // Powerline is whitespace
                if (isPowerline(prev_cp)) break :prev;

                if (ziglyph.general_category.isPrivateUse(prev_cp)) {
                    break :text .constrained;
                }
            }

            // If the next cell is empty, then we allow it to use the
            // full glyph size.
            const next_cp = next_cp: {
                var copy = cell_pin;
                copy.x += 1;
                const next_cell = copy.rowAndCell().cell;
                break :next_cp next_cell.codepoint();
            };
            if (next_cp == 0 or
                isSpace(next_cp) or
                isPowerline(next_cp))
            {
                break :text .normal;
            }

            // Must be constrained
            break :text .constrained;
        },
    };
}

// Some general spaces, others intentionally kept
// to force the font to render as a fixed width.
fn isSpace(char: u21) bool {
    return switch (char) {
        0x0020, // SPACE
        0x2002, // EN SPACE
        => true,
        else => false,
    };
}

// Returns true if the codepoint is a part of the Powerline range.
fn isPowerline(char: u21) bool {
    return switch (char) {
        0xE0B0...0xE0C8, 0xE0CA, 0xE0CC...0xE0D2, 0xE0D4 => true,
        else => false,
    };
}
