# Example: `ghostty-vt` Kitty Graphics Protocol

This example shows how to accept images sent with the Kitty Graphics
Protocol and find out what to draw. It:

1. Installs a PNG decoder with the system interface (`ghostty_sys_set`).
2. Sends two images with `ghostty_terminal_vt_write`. One is placed at
   a cell, and the other is shown with Unicode placeholder cells.
3. Reads both images from the render state's image list, which gives
   each one's position, size, source rectangle, layer and z-index.
4. Reads each image's pixels from the Kitty graphics storage.
5. Plays a short animation by calling
   `ghostty_kitty_graphics_animation_tick`.

The render state's image list is the only place a renderer needs to
read positions from. It includes every image on screen, however the
program placed it. The Kitty graphics storage is only used for pixels.
If you also draw placements from the storage's placement iterator, they
are drawn twice.

## Knowing What Changed

Two values tell a renderer what to redo on each frame:

- `GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION` belongs to the
  whole list. It tells you when to read the list again.
- `GHOSTTY_KITTY_IMAGE_DATA_GENERATION` belongs to a single image. It
  tells you when to upload that image's pixels again. The render state
  reports the same value for each image as
  `GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION`.

The example draws three frames. The first reads the list. The second
changes nothing, so it keeps the list it has. Before the third, new
output scrolls the screen by two rows, which moves both images, so the
third reads the list again.

The storage's own `GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION` changes when
a program sends, places or deletes an image, but not when images only
move on screen. It can't tell you when to read the list again.

## Building

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
