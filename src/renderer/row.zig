const terminal = @import("../terminal/main.zig");

// TODO: Test neverExtendBg function

/// Returns true if the row of this pin should never have its background
/// color extended for filling padding space in the renderer. This is
/// a set of heuristics that help making our padding look better.
pub fn neverExtendBg(
    row: terminal.page.Row,
    cells: []const terminal.page.Cell,
    styles: []const terminal.Style,
    palette: *const terminal.color.Palette,
    default_background: terminal.color.RGB,
) bool {
    // Any semantic prompts should not have their background extended
    // because prompts often contain special formatting (such as
    // powerline) that looks bad when extended.
    switch (row.semantic_prompt) {
        .prompt, .prompt_continuation, .input => return true,
        .unknown, .command => {},
    }

    for (0.., cells) |x, *cell| {
        // If any cell has a default background color then we don't
        // extend because the default background color probably looks
        // good enough as an extension.
        switch (cell.content_tag) {
            // If it is a background color cell, we check the color.
            .bg_color_palette, .bg_color_rgb => {
                const s: terminal.Style = if (cell.hasStyling()) styles[x] else .{};
                const bg = s.bg(cell, palette) orelse return true;
                if (bg.eql(default_background)) return true;
            },

            // If its a codepoint cell we can check the style.
            .codepoint, .codepoint_grapheme => {
                // For codepoint containing, we also never extend bg
                // if any cell has a powerline glyph because these are
                // perfect-fit.
                switch (cell.codepoint()) {
                    // Powerline
                    0xE0B0...0xE0C8,
                    0xE0CA,
                    0xE0CC...0xE0D2,
                    0xE0D4,
                    => return true,

                    else => {},
                }

                // Never extend a cell that has a default background.
                // A default background is applied if there is no background
                // on the style or the explicitly set background
                // matches our default background.
                const s: terminal.Style = if (cell.hasStyling()) styles[x] else .{};
                const bg = s.bg(cell, palette) orelse return true;
                if (bg.eql(default_background)) return true;
            },
        }
    }

    return false;
}
