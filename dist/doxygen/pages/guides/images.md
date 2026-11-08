# Images {#guide-images}

A program running in your terminal can send images and ask you to draw them.
Today that means the
[Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).

Images don't fit in cells, so the render state's rows can't carry them. There
are two parts instead. The terminal keeps every image a program sends in an
image storage, and that's where the pixels are. The render state works out what
to draw, where, how big and in what order. You read the list from the render
state and the pixels from the storage, and you never have to track a cell
yourself.

If you don't draw images, you can skip this page. Just know that the protocol is
on by default, so programs can fill the storage even if you never read it. Set
the limit below to zero to turn it off.

## Setting up {#guide-images-setup}

Kitty graphics are on by default with a 10 MB storage limit. Change the limit
with #GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT. A limit of zero disables
the protocol and deletes every stored image and placement. If Kitty graphics
were disabled at build time, this option returns `GHOSTTY_UNSUPPORTED`.

```c
uint64_t storage_limit = 64 * 1024 * 1024;  // 64 MiB
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                     &storage_limit);
```

The terminal also needs a cell size. Image sizes depend on the size of a cell in
pixels, which you set with ghostty_terminal_resize(). Without it there's nothing
to draw and the image list is empty.

Programs can send image data directly in the sequence. Loading it from a file, a
temporary file or shared memory is off by default. Turn those on with
#GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
#GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE and
#GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM.

Each screen, main and alternate, has its own storage. Get a handle to the active
one with ghostty_terminal_get() and #GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS. The
handle is borrowed, so see @ref guide-images-lifetime before you keep one.

## Decoding PNGs {#guide-images-png}

We don't ship a PNG decoder. You bring your own, so use whatever library you
already have. Without one, PNG images are rejected.

Install it with ghostty_sys_set() and #GHOSTTY_SYS_OPT_DECODE_PNG. This is a
process-global setting, not a terminal one. Set it at startup, before you use
anything that depends on it. ghostty_sys_set() isn't thread-safe, so call it
before any other thread uses the library, and never while one does. Passing
`NULL` clears the decoder and turns PNG support off again.

The callback gets the PNG bytes and fills in a GhosttySysImage. Pixels are 8-bit
RGBA, row by row from the top-left, with no padding, so a complete image is
`width * height * 4` bytes. Allocate them with ghostty_alloc() and the allocator
we pass you, and return true. We own the buffer after that. `data_len` must be
the exact size you asked the allocator for, because we use it to free the
buffer.

That allocator limits how much memory one image can use, so ghostty_alloc() can
return `NULL` for a very large image. Treat that as a failure: free anything you
allocated and return false, and the image is rejected. GhosttySysDecodePngFn has
the rest of the contract.

This example shows the shape of a decoder, but it doesn't actually decode
anything. It hardcodes one red pixel.

@snippet c-vt-kitty-graphics/src/main.c kitty-graphics-decode-png

Full program: @ref c-vt-kitty-graphics/src/main.c

## Drawing images {#guide-images-drawing}

The render state gives you the images to draw as a list of placements, which you
read with a GhosttyRenderStateImageIterator. Each placement is one rectangle of
one image:

- What to draw: the image's protocol and ID, plus a source rectangle that
  selects part of the image in image pixels.
- Where to draw it: the top-left cell, relative to the viewport, plus a pixel
  offset within that cell.
- How big to draw it: a destination size in pixels. The image is already scaled
  to fit its cells.
- In what order to draw it: a layer (below cell backgrounds, below text, or
  above text) and a z-index within the layer.

These values mean the same thing for every protocol, so one drawing routine
handles all of them. The only part that depends on the protocol is getting the
pixels. Use the placement's protocol to pick the right storage and its image ID
to look the image up.

Later versions may add more protocols and more kinds of placements. Skip any
placement whose protocol you don't support, and your renderer keeps working when
that happens.

```c
// Create the iterator once and reuse it for every frame.
GhosttyRenderStateImageIterator images = NULL;
ghostty_render_state_image_iterator_new(NULL, &images);

// Each frame, after ghostty_render_state_update().
ghostty_render_state_get(
    state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &images);

while (ghostty_render_state_image_iterator_next(images)) {
  GhosttyImageProtocol protocol;
  GhosttyImageLayer layer;
  uint32_t image_id, offset_x, offset_y, width, height;
  uint32_t src_x, src_y, src_width, src_height;
  uint64_t generation;
  int32_t col, row, z;

  GhosttyRenderStateImageData keys[] = {
    GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_Z,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH,
    GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT,
  };
  void* values[] = {
    &protocol, &image_id, &generation, &layer, &z, &col, &row,
    &offset_x, &offset_y, &width, &height,
    &src_x, &src_y, &src_width, &src_height,
  };
  ghostty_render_state_image_get_multi(images, 15, keys, values, NULL);

  // Your renderer: find the texture for this image. Only read the
  // pixels when you don't have a texture for this protocol, ID and
  // generation yet.
  Texture* texture = texture_cache_find(protocol, image_id, generation);
  if (texture == NULL) {
    switch (protocol) {
    case GHOSTTY_IMAGE_PROTOCOL_KITTY:
      // Look up image_id with ghostty_kitty_graphics_image(), read its
      // pixels with ghostty_kitty_graphics_image_get(), and upload.
      texture = upload_kitty_image(image_id, generation);
      break;
    default:
      // A protocol this renderer doesn't support yet.
      continue;
    }
  }

  // The destination rectangle in pixels, relative to the top-left
  // corner of the viewport. It can start above or left of the
  // viewport, so clip it when drawing.
  int32_t x = col * cell_width + (int32_t)offset_x;
  int32_t y = row * cell_height + (int32_t)offset_y;

  // Queue the image. Sort the queue by layer and then z before
  // drawing, since iteration order is not drawing order.
  queue_image(texture, layer, z, x, y, width, height,
              src_x, src_y, src_width, src_height);
}

// When you no longer need it:
ghostty_render_state_image_iterator_free(images);
```

Results last until the next update. Like rows, they belong to the render state
and can be read without access to the terminal. After each update, fill the
iterator again before you read it.

The pixels are different, because the render state doesn't copy them. It only
knows where to draw. Read pixels from the terminal while you still have access
to it, for example right after the update while you hold your terminal lock.

Each entry has an image ID. Look it up with ghostty_kitty_graphics_image(), then
read the image's size, pixel format and pixels with
ghostty_kitty_graphics_image_get(). The pixels are always decoded and
uncompressed, so you can upload them as they are. This example reads a list and
prints what it would draw, including the pixels:

@snippet c-vt-kitty-graphics/src/main.c kitty-graphics-draw

Full program: @ref c-vt-kitty-graphics/src/main.c

The list holds every Kitty image on screen, however the program placed it.
Earlier versions left some images out, so renderers had to draw them from the
storage's placement iterator. That's no longer needed. If your renderer still
draws from that iterator, stop, or those images are drawn twice. See @ref
guide-images-inspecting for what it's for.

## Images partly outside the captured rows {#guide-images-clipping}

An image is in the list when any part of it is in the captured rows, which are
the viewport plus any overscan rows. See @ref guide-rendering-overscan.

Images shown with placeholder cells are split into one placement per row of
cells, so each of those placements is always inside the captured rows.

Every other placement is reported at its full size, even when only part of it
can be seen. Its #GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL can be negative,
and its #GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW can be above the first
overscan row. It can also extend past the right or bottom edge. So clip what you
draw to the viewport, or to the captured rows if you draw overscan rows. Most
graphics APIs can do this for you with a scissor or clip rectangle.

For example, with no overscan, an image 4 rows tall whose top row scrolled 2
rows above the viewport has a row of -2 and covers 4 rows. Draw it at its full
size starting 2 rows above the viewport, clipped to the viewport. Its bottom 2
rows show at the top of the viewport.

## Knowing what changed {#guide-images-changes}

Most frames don't change any image. A program prints text or moves the cursor,
and every image stays where it was. So a renderer can skip most of its image
work. Two values tell you what to redo.

#GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION belongs to the render
state's whole list. It tells you when to read the list again. After each update,
compare it with the value from the last time you read the list. If they match,
the list is the same as before, and you can keep drawing what you built last
time:

```c
// Kept by your renderer between frames. The flag makes sure the first
// frame always reads the list.
uint64_t last_generation = 0;
bool have_draw_list = false;

// Each frame, after ghostty_render_state_update():
uint64_t generation = 0;
ghostty_render_state_get(
    state, GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION,
    &generation);
if (!have_draw_list || generation != last_generation) {
  last_generation = generation;
  have_draw_list = true;

  // Your renderer: read the iterator as in the example above and
  // build a new queue of images to draw.
  rebuild_image_queue(state, images);
}
draw_image_queue();
```

The value changes when an update adds or removes an image, moves one, changes
which part of one is shown, or changes the pixels of one. It stays the same when
only text changes, as long as the changed rows had no placeholder cells before
or after the change.

A new value means "read the list again". It doesn't promise that anything on
screen moved. The value can change even when every image ends up exactly where
it was, for example:

- When a program rewrites a row that has placeholder cells.
- When a program changes any image or placement while images shown with
  placeholder cells are on screen.

Only compare the value for equality, and only with the last value you read from
the same render state. It wraps around, so a larger value doesn't mean a newer
one. It's always 0 when Kitty graphics are disabled.

#GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION belongs to a single image. It
tells you when to upload that image's pixels again. It changes when a program
sends the image again and on every animation frame. The render state reports the
same value for each entry as #GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION,
so you can check your texture cache without touching the storage, and most
frames don't touch the terminal at all.

Use the image generation as part of your texture cache key. Don't rely on the
image's size or data length instead. A program can send new pixels with the same
size under the same ID.

Here's a frame loop that reads the list only when it changed:

@snippet c-vt-kitty-graphics/src/main.c kitty-graphics-frame

Full program: @ref c-vt-kitty-graphics/src/main.c

The storage also has a generation of its own,
#GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION. It changes whenever a program sends,
places or deletes an image, but not when images only move on screen. So it can't
tell you when to read the render state's list again. It's useful for work that
only depends on what the storage holds, such as freeing the textures of deleted
images.

The two storage generations are never reused, not even across the main and
alternate screens, terminal resets, or different terminals. That makes either
one safe to use as a cache key on its own.

## Placements at a cell {#guide-images-fixed}

You draw every placement the same way, so you can skip the next three sections
unless you're curious how a list entry got there, or you're reading
#GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_KIND.

A program can place an image at a cell on the screen. The image is attached to
that cell, so it moves when the text moves: when new output scrolls the screen,
when a program scrolls part of the screen, and when the viewport scrolls through
the scrollback.

The render state finds the position of these images during each update, so you
don't need to track the cells yourself. This costs very little on a typical
frame, including frames where the viewport scrolls.

## Placeholders {#guide-images-placeholders}

A program can also place an image with text. It creates a virtual placement,
which has no position of its own, and prints placeholder characters (U+10EEEE)
wherever the image should appear. Each placeholder cell says which image it
shows and which piece of that image belongs in the cell. Programs such as tmux
use this so that images scroll, move and disappear along with the text around
them.

Only the cells know where these images are, so the storage can't tell you where
to draw them. The render state works it out during each update. It finds the
placeholder cells, groups neighboring cells that show the same image into runs,
and calculates which part of the image each run shows. It only looks at rows
that changed, so this costs very little on a typical frame.

A virtual placement usually turns into several entries in the list, one for each
row of placeholder cells. For example, an image shown in a block of 10 columns
by 4 rows of placeholders gives 4 entries, each 10 cells wide and 1 cell tall,
and each drawing a quarter of the image. Drawn together, they form the whole
image.

## Relative placements {#guide-images-relative}

A program can place an image relative to another placement, its parent. The
image is drawn a number of cells to the right of and below its parent. Negative
numbers move it left or up. The parent can be relative to another placement too,
so placements can form a chain.

The render state follows the chain to the placement at its start and positions
the image from there:

- If the chain starts at an image placed at a cell, the image is drawn from that
  cell, and moves whenever that cell moves.
- If the chain starts at a virtual placement, the image is drawn from the
  top-left corner of that placement's placeholder cells. If none of those cells
  are in the captured rows, the image isn't in the list.

For example, an image placed 3 columns right of and 2 rows below a parent at
column 2, row 1 is drawn at column 5, row 3. Like other placements, it's in the
list when any part of it is in the captured rows, even if its parent isn't.

## Animation {#guide-images-animation}

Programs can send images with several frames and ask the terminal to play them,
much like an animated GIF. The terminal stores every frame, but it has no timer
of its own. You drive playback by calling
ghostty_kitty_graphics_animation_tick().

Each call shows whichever frame is due at the time you pass in. When an image
moves to a new frame, #GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS returns the
pixels of the new frame and #GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION
returns a new value. If you already cache textures by image generation, new
frames appear without any extra work.

The tick also tells you when the next frame is due. Use that time to schedule a
single redraw instead of calling the tick in a loop:

1. Call the tick each time you prepare a frame to draw, as long as the storage
   holds at least one image.
2. If it returns `GHOSTTY_SUCCESS`, schedule one redraw at the returned time.
   Don't schedule it sooner than your shortest frame interval, for example 8 ms
   for a 120 Hz display.
3. If it returns `GHOSTTY_NO_VALUE`, nothing is playing. Don't schedule
   anything.

You never need to watch for animations starting. A program starts or resumes
playback by writing a command to the terminal, and that write already gives you
a reason to redraw. The tick on that redraw picks up the animation. A terminal
with no playing animations costs nothing extra.

Here's a helper that follows these steps. A renderer calls it once per frame and
uses the result to schedule the next redraw:

@snippet c-vt-kitty-graphics/src/main.c kitty-graphics-animation-tick

Full program: @ref c-vt-kitty-graphics/src/main.c

This plays a two-frame animation with that helper. It uses a pretend clock so
that it runs instantly:

@snippet c-vt-kitty-graphics/src/main.c kitty-graphics-animation-play

Full program: @ref c-vt-kitty-graphics/src/main.c

## Inspecting the storage {#guide-images-inspecting}

A renderer doesn't need this section. A GhosttyKittyGraphicsPlacementIterator
lists every placement in the storage, including placements that are off screen
and virtual placements. It's for tools such as debuggers or tests that need to
see what the storage holds.

1. Create an iterator with ghostty_kitty_graphics_placement_iterator_new().
2. Fill it from the storage with ghostty_kitty_graphics_get() and
   #GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR.
3. Optionally limit it to one layer with
   ghostty_kitty_graphics_placement_iterator_set().
4. Move to each placement with ghostty_kitty_graphics_placement_next() and read
   its values with ghostty_kitty_graphics_placement_get().
5. Free the iterator with ghostty_kitty_graphics_placement_iterator_free().

These functions work out the geometry of the iterator's current placement from
the storage:

- ghostty_kitty_graphics_placement_pixel_size(): the size to draw the image at,
  in pixels.
- ghostty_kitty_graphics_placement_grid_size(): the number of columns and rows
  of cells it covers.
- ghostty_kitty_graphics_placement_viewport_pos(): the top-left cell, relative
  to the viewport.
- ghostty_kitty_graphics_placement_source_rect(): the part of the image to draw,
  in image pixels.
- ghostty_kitty_graphics_placement_rect(): the cells it covers, as a
  GhosttySelection.
- ghostty_kitty_graphics_placement_render_info(): all of the above except the
  selection, in one call.

They only know about placements at a cell and placements relative to one. They
can't find virtual placements, or placements relative to a virtual placement,
because those depend on the cells. The render state gives the same values for
every entry in its list, so prefer it whenever you're drawing.

## Lifetime {#guide-images-lifetime}

Everything borrowed from the terminal is short-lived. GhosttyKittyGraphics and
GhosttyKittyGraphicsImage handles stay valid until the next call that changes
the terminal, such as ghostty_terminal_vt_write() or ghostty_terminal_reset().
So get them again after each of those.

ghostty_kitty_graphics_animation_tick() changes the storage too. It invalidates
image handles and image data pointers, so look images up again afterward. The
GhosttyKittyGraphics handle itself stays valid.

The placement iterator belongs to you and you must free it, but the values it
returns are only valid until the terminal changes.

## Putting it together {#guide-images-example}

This creates a terminal, places one image at a cell and another with placeholder
cells, lists both from the render state, and reads each image's pixels from the
storage.

@snippet c-vt-kitty-graphics/src/main.c kitty-graphics-main

Full program: @ref c-vt-kitty-graphics/src/main.c
