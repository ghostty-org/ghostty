# This is a _special_ directory.

The files in this directory are imported by `../Face.zig` and scanned for pub
functions with names matching a specific format, which are then used to handle
drawing specified codepoints.

## IMPORTANT

When you add a new file here, you need to add the corresponding import in
`../Face.zig` for its draw functions to be picked up. I tried dynamically
listing these files to do this automatically but it was more pain than it
was worth.

## `draw*` functions

Any function named `draw<CODEPOINT>` or `draw<MIN>_<MAX>` will be used to
draw the codepoint or range of codepoints specified in the name. These are
hex-encoded values with upper case letters.

`draw*` functions are provided with these arguments:

```zig
/// The codepoint being drawn. For single-codepoint draw functions this can
/// just be discarded, but it's needed for range draw functions to determine
/// which value in the range needs to be drawn.
cp: u32,
/// The canvas on which to draw the codepoint.
////
/// This canvas has been prepared with an extra quarter of the width/height on
/// each edge, and its transform has been set so that [0, 0] is still the upper
/// left of the cell and [width, height] is still the bottom right; in order to
/// draw above or to the left, use negative values, and to draw below or to the
/// right use values greater than the width or the height.
///
/// Because the canvas has been prepared this way, it's possible to draw glyphs
/// that exit the cell bounds by some amount- an example of when this is useful
/// is in drawing box-drawing diagonals, with enough overlap so that they can
/// seamlessly connect across corners of cells.
canvas: *font.sprite.Canvas,
/// The width of the cell to draw for.
width: u32,
/// The height of the cell to draw for.
height: u32,
/// The font grid metrics.
metrics: font.Metrics,
```

`draw*` functions may only return `DrawFnError!void` (defined in `../Face.zig`).

## `special.zig`

The functions in `special.zig` are not for drawing unicode codepoints,
rather their names match the enum tag names in the `Sprite` enum from
`src/font/sprite.zig`. They are called with the same arguments as the
other `draw*` functions.
