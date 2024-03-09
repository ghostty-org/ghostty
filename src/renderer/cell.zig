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
    cell_pin: terminal.Pin,
    shaper_run: font.shape.TextRun,
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
            const cell = cell_pin.rowAndCell().cell;
            const cp = cell.codepoint();

            if (!ziglyph.general_category.isPrivateUse(cp) and
                !ziglyph.blocks.isDingbats(cp))
            {
                break :text .normal;
            }

            // We exempt the Powerline range from this since they exhibit
            // box-drawing behavior and should not be constrained.
            if (isPowerline(cp)) {
                break :text .normal;
            }

            // If we are at the end of the screen its definitely constrained
            if (cell_pin.x == cell_pin.page.data.size.cols - 1) break :text .constrained;

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
                next_cp == ' ' or
                isPowerline(next_cp))
            {
                break :text .normal;
            }

            // Must be constrained
            break :text .constrained;
        },
    };
}

// Returns true if the codepoint is a part of the Powerline range.
fn isPowerline(char: u21) bool {
    return switch (char) {
        0xE0B0...0xE0C8, 0xE0CA, 0xE0CC...0xE0D2, 0xE0D4 => true,
        else => false,
    };
}
