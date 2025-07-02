//! Glyph is a single loaded glyph for a face.
const Glyph = @This();

/// width of glyph in pixels
width: u32,

/// height of glyph in pixels
height: u32,

/// left bearing
offset_x: i32,

/// top bearing
offset_y: i32,

/// coordinates in the atlas of the top-left corner. These have to
/// be normalized to be between 0 and 1 prior to use in shaders.
atlas_x: u32,
atlas_y: u32,

/// horizontal position to increase drawing position for strings
advance_x: f32,

/// Whether we drew this glyph ourselves with the sprite font.
sprite: bool = false,
