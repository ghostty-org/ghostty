#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [kitty-graphics-decode-png]
/**
 * Minimal PNG decoder callback for the sys interface.
 *
 * A real implementation would use a PNG library (libpng, stb_image, etc.)
 * to decode the PNG data. This example uses a hardcoded 1x1 red pixel
 * since we know exactly what image we're sending.
 *
 * WARNING: This is only an example for providing a callback, it DOES NOT 
 * actually decode the PNG it is passed. It hardcodes a response.
 */
bool decode_png(void* userdata,
                const GhosttyAllocator* allocator,
                const uint8_t* data,
                size_t data_len,
                GhosttySysImage* out) {
  int* count = (int*)userdata;
  (*count)++;
  printf("  decode_png called (size=%zu, call #%d)\n", data_len, *count);

  /* Allocate RGBA pixel data through the provided allocator. */
  const size_t pixel_len = 4;  /* 1x1 RGBA */
  uint8_t* pixels = ghostty_alloc(allocator, pixel_len);
  if (!pixels) return false;

  /* Fill with red (R=255, G=0, B=0, A=255). */
  pixels[0] = 255;
  pixels[1] = 0;
  pixels[2] = 0;
  pixels[3] = 255;

  out->width = 1;
  out->height = 1;
  out->data = pixels;
  out->data_len = pixel_len;
  return true;
}
//! [kitty-graphics-decode-png]

//! [kitty-graphics-write-pty]
/**
 * write_pty callback to capture terminal responses.
 *
 * The Kitty graphics protocol sends an APC response back to the pty
 * when an image is loaded (unless suppressed with q=2).
 */
void on_write_pty(GhosttyTerminal terminal,
                  void* userdata,
                  const uint8_t* data,
                  size_t len) {
  (void)terminal;
  (void)userdata;
  printf("  response (%zu bytes): ", len);
  fwrite(data, 1, len, stdout);
  printf("\n");
}
//! [kitty-graphics-write-pty]

//! [kitty-graphics-animation-tick]
/* The shortest time between two redraws. About 8 ms suits a 120 Hz display. */
#define MIN_FRAME_INTERVAL_MS 8

/**
 * Advance any playing animations while preparing a frame to draw.
 *
 * Call this once per frame, before drawing images. It returns how many
 * milliseconds to wait before the next redraw, or -1 if no animation is
 * playing. In that case, don't schedule a redraw for animations at all.
 * A program that starts an animation does so by writing to the
 * terminal, which already causes a redraw.
 *
 * `now_ms` comes from a clock you choose, such as milliseconds since
 * your app started. Always use the same clock with the same starting
 * point.
 */
int64_t tick_animations(GhosttyKittyGraphics graphics, uint64_t now_ms) {
  uint64_t next_ms = 0;
  if (ghostty_kitty_graphics_animation_tick(graphics, now_ms, &next_ms) !=
      GHOSTTY_SUCCESS) {
    return -1;
  }

  /* next_ms is an absolute time. Turn it into a delay from now. */
  uint64_t delay_ms = next_ms > now_ms ? next_ms - now_ms : 0;
  if (delay_ms < MIN_FRAME_INTERVAL_MS) delay_ms = MIN_FRAME_INTERVAL_MS;
  return (int64_t)delay_ms;
}
//! [kitty-graphics-animation-tick]

//! [kitty-graphics-animation-play]
/** Print the first pixel and the generation of an image. */
void print_image(GhosttyKittyGraphics graphics, uint32_t image_id) {
  GhosttyKittyGraphicsImage image =
      ghostty_kitty_graphics_image(graphics, image_id);
  const uint8_t* pixels = NULL;
  uint64_t generation = 0;
  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR,
                                   &pixels);
  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION,
                                   &generation);
  printf("pixel=(%u,%u,%u) generation=%llu", pixels[0], pixels[1], pixels[2],
         (unsigned long long)generation);
}

/**
 * Play a two-frame animation using tick_animations().
 *
 * A real app waits for the delay that tick_animations() returns. To keep
 * this example quick, a pretend clock jumps ahead by that delay instead.
 */
int run_animation(GhosttyTerminal terminal) {
  /*
   * These commands set up the animation:
   *
   *   a=T  Send a red 1x1 RGBA image with ID 2 and display it.
   *   a=f  Add a blue second frame that shows for 40 ms.
   *   a=a  Make the first frame show for 30 ms. It starts at 0 ms,
   *        which would mean the frame is skipped.
   *   a=a  Start playing on a loop (s=3).
   *
   * q=2 tells the terminal not to send replies.
   */
  const char* cmds =
    "\x1b_Ga=T,f=32,i=2,s=1,v=1,q=2;/wAA/w==\x1b\\"
    "\x1b_Ga=f,f=32,i=2,s=1,v=1,z=40,q=2;AAD//w==\x1b\\"
    "\x1b_Ga=a,i=2,r=1,z=30,q=2\x1b\\"
    "\x1b_Ga=a,i=2,s=3,q=2\x1b\\";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)cmds, strlen(cmds));

  GhosttyKittyGraphics graphics = NULL;
  if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                           &graphics) != GHOSTTY_SUCCESS || !graphics) {
    fprintf(stderr, "Failed to get kitty graphics storage\n");
    return 1;
  }

  /* Draw three frames, following each delay. */
  uint64_t now_ms = 0;
  for (int i = 0; i < 3; i++) {
    int64_t delay_ms = tick_animations(graphics, now_ms);

    /*
     * The tick invalidates image handles, so print_image() looks the
     * image up again. The generation changes whenever the frame does.
     */
    printf("  t=%llu ms: ", (unsigned long long)now_ms);
    print_image(graphics, 2);
    printf(", next redraw in %lld ms\n", (long long)delay_ms);

    now_ms += (uint64_t)delay_ms;
  }

  /* Stop playback (s=1). Once stopped, the tick asks for no redraws. */
  const char* stop = "\x1b_Ga=a,i=2,s=1,q=2\x1b\\";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)stop, strlen(stop));

  /* Writing to the terminal invalidates the storage handle. Get it again. */
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                       &graphics);
  if (tick_animations(graphics, now_ms) < 0) {
    printf("  t=%llu ms: stopped, no redraw needed\n",
           (unsigned long long)now_ms);
  }

  return 0;
}
//! [kitty-graphics-animation-play]

//! [kitty-graphics-draw]
/** A short name for each kind of Kitty placement, for printing. */
const char* kind_name(GhosttyRenderStateKittyPlacementKind kind) {
  switch (kind) {
  case GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_VIRTUAL: return "virtual";
  case GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_RELATIVE: return "relative";
  case GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_FIXED: return "fixed";
  default: return "unknown";
  }
}

/** A short name for each image layer, for printing. */
const char* layer_name(GhosttyRenderStateImageLayer layer) {
  switch (layer) {
  case GHOSTTY_RENDER_STATE_IMAGE_LAYER_BELOW_BACKGROUND: return "below-bg";
  case GHOSTTY_RENDER_STATE_IMAGE_LAYER_BELOW_TEXT: return "below-text";
  case GHOSTTY_RENDER_STATE_IMAGE_LAYER_ABOVE_TEXT: return "above-text";
  default: return "unknown";
  }
}

/**
 * Read the render state's image list, the way a renderer builds its list
 * of images to draw. Returns the number of images, or -1 on error.
 *
 * The list holds every Kitty image on screen, however the program placed
 * it, with its position, size and draw order worked out. The Kitty
 * graphics storage is only used to read pixels.
 *
 * A real renderer would find or upload a texture for each image and
 * queue it for drawing, sorted by layer and then z. This example prints
 * what it would draw instead.
 */
int draw_images(GhosttyRenderState state,
                GhosttyRenderStateImageIterator images,
                GhosttyTerminal terminal) {
  /* Fill the iterator from the last update. */
  if (ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR,
                               &images) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to get image iterator\n");
    return -1;
  }

  /* The storage is only needed to read pixels. */
  GhosttyKittyGraphics graphics = NULL;
  if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                           &graphics) != GHOSTTY_SUCCESS || !graphics) {
    fprintf(stderr, "Failed to get kitty graphics storage\n");
    return -1;
  }

  int count = 0;
  while (ghostty_render_state_image_iterator_next(images)) {
    GhosttyImageProtocol protocol;
    ghostty_render_state_image_get(
        images, GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL, &protocol);

    /* Skip protocols this renderer doesn't support. */
    if (protocol != GHOSTTY_IMAGE_PROTOCOL_KITTY) continue;

    GhosttyRenderStateKittyPlacementKind kind;
    GhosttyRenderStateImageLayer layer;
    uint32_t image_id, placement_id, cols, rows, offset_x, offset_y;
    uint32_t width, height, src_x, src_y, src_width, src_height;
    uint64_t generation;
    int32_t col, row, z;

    GhosttyRenderStateImageData keys[] = {
      GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_KIND,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_PLACEMENT_ID,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_Z,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_COLS,
      GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_ROWS,
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
      &image_id, &generation, &kind, &placement_id, &layer, &z, &col, &row,
      &cols, &rows, &offset_x, &offset_y, &width, &height,
      &src_x, &src_y, &src_width, &src_height,
    };
    size_t key_count = sizeof(keys) / sizeof(keys[0]);
    if (ghostty_render_state_image_get_multi(images, key_count, keys, values,
                                             NULL) != GHOSTTY_SUCCESS) {
      fprintf(stderr, "Failed to read image placement\n");
      return -1;
    }

    count++;
    printf("  image #%d: kind=%s image_id=%u placement_id=%u\n", count,
           kind_name(kind), image_id, placement_id);
    printf("    layer=%s z=%d cell=(%d,%d) cells=%ux%u offset=(%u,%u)\n",
           layer_name(layer), z, col, row, cols, rows, offset_x, offset_y);
    printf("    size=%ux%u source=(%u,%u %ux%u)\n", width, height, src_x,
           src_y, src_width, src_height);

    /*
     * Read the pixels to upload them as a texture. A real renderer keys
     * its textures by protocol, image ID and image generation, and only
     * gets here when it has no texture for that key yet. The generation
     * changes whenever the pixels do, so most frames skip this.
     */
    GhosttyKittyGraphicsImage image =
        ghostty_kitty_graphics_image(graphics, image_id);
    if (!image) continue;

    uint32_t image_width = 0, image_height = 0;
    GhosttyKittyImageFormat format = 0;
    const uint8_t* pixels = NULL;
    size_t data_len = 0;
    ghostty_kitty_graphics_image_get_multi(image, 5,
        (GhosttyKittyGraphicsImageData[]){
            GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
            GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
            GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
            GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR,
            GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN,
        },
        (void*[]){ &image_width, &image_height, &format, &pixels, &data_len },
        NULL);
    printf("    pixels: %ux%u format=%d data_len=%zu generation=%llu\n",
           image_width, image_height, format, data_len,
           (unsigned long long)generation);
  }

  return count;
}
//! [kitty-graphics-draw]

//! [kitty-graphics-frame]
/**
 * Draw three frames, reading the image list only when it changed.
 *
 * Each frame updates the render state and compares the placements
 * generation with the one from the last time the list was read. The
 * first frame always reads the list. The second frame changes nothing,
 * so it keeps the list it has. Before the third frame, new output
 * scrolls the screen by two rows, which moves both images, so the third
 * frame reads the list again.
 */
int run_frames(GhosttyTerminal terminal) {
  /* Create the render state and the image iterator once, and reuse them. */
  GhosttyRenderState state = NULL;
  if (ghostty_render_state_new(NULL, &state) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create render state\n");
    return 1;
  }
  GhosttyRenderStateImageIterator images = NULL;
  if (ghostty_render_state_image_iterator_new(NULL, &images) !=
      GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create image iterator\n");
    ghostty_render_state_free(state);
    return 1;
  }

  /* The flag makes sure the first frame always reads the list. */
  uint64_t last_generation = 0;
  bool have_draw_list = false;

  int result = 0;
  for (int frame = 1; frame <= 3; frame++) {
    if (frame == 3) {
      /* Move to the bottom row and print two newlines to scroll. */
      const char* scroll = "\x1b[24;1H\r\n\r\n";
      ghostty_terminal_vt_write(terminal, (const uint8_t*)scroll,
                                strlen(scroll));
    }

    if (ghostty_render_state_update(state, terminal) != GHOSTTY_SUCCESS) {
      fprintf(stderr, "Failed to update render state\n");
      result = 1;
      break;
    }

    uint64_t generation = 0;
    ghostty_render_state_get(
        state, GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION,
        &generation);
    if (have_draw_list && generation == last_generation) {
      printf("\nFrame %d: no image changed, keep drawing the last list\n",
             frame);
      continue;
    }
    last_generation = generation;
    have_draw_list = true;

    printf("\nFrame %d: images changed, reading the list:\n", frame);
    int count = draw_images(state, images, terminal);
    if (count < 0) {
      result = 1;
      break;
    }
    printf("Total images: %d\n", count);
  }

  ghostty_render_state_image_iterator_free(images);
  ghostty_render_state_free(state);
  return result;
}
//! [kitty-graphics-frame]

//! [kitty-graphics-main]
int main() {
  /* Install the PNG decoder via the sys interface. */
  int decode_count = 0;
  ghostty_sys_set(GHOSTTY_SYS_OPT_USERDATA, &decode_count);
  ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, (const void*)decode_png);

  /* Create a terminal with Kitty graphics enabled. */
  GhosttyTerminal terminal = NULL;
  if (ghostty_terminal_new(NULL, &terminal, 80, 24) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create terminal\n");
    return 1;
  }

  /* Set the cell size in pixels. Image sizes depend on it. */
  ghostty_terminal_resize(terminal, 80, 24, 8, 16);

  /* Set a storage limit to enable Kitty graphics. */
  uint64_t storage_limit = 64 * 1024 * 1024;  /* 64 MiB */
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                       &storage_limit);

  /* Install write_pty to see the protocol response. */
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       (const void*)on_write_pty);

  /* Move the cursor to row 10 so the images have room to scroll up. */
  const char* move = "\x1b[10;1H";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)move, strlen(move));

  /*
   * Send a 1x1 PNG image and place it at the cursor. The image is
   * attached to that cell, so it moves when the text moves.
   *
   * The escape sequence is:
   *   ESC _G a=T,f=100,q=1; <base64 PNG data> ESC \
   *
   * Where:
   *   a=T    transmit the image and place it
   *   f=100  the data is a PNG
   *   q=1    only reply on errors (q=0 would also reply on success)
   */
  printf("Sending Kitty graphics PNG image:\n");
  const char* kitty_cmd =
    "\x1b_Ga=T,f=100,q=1;"
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA"
    "DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    "\x1b\\";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)kitty_cmd,
                            strlen(kitty_cmd));

  printf("PNG decode calls: %d\n", decode_count);

  /*
   * Show a second image with placeholder cells. First send a green 1x1
   * image with ID 3 and give it a virtual placement 2 columns wide and
   * 1 row tall (U=1). Then, on the next row, print two placeholder
   * characters (U+10EEEE) where the image should appear:
   *
   *   ESC[38;5;3m    the foreground color says which image: ID 3
   *   U+0305 U+0305  the first cell shows row 0, column 0 of the image
   *   U+0305 U+030D  the second cell shows row 0, column 1
   *
   * The image moves with those cells, like text.
   */
  const char* placeholder_cmds =
    "\x1b_Ga=T,U=1,f=32,i=3,s=1,v=1,c=2,r=1,q=2;AP8A/w==\x1b\\"
    "\r\n\x1b[38;5;3m"
    "\xf4\x8e\xbb\xae\xcc\x85\xcc\x85"
    "\xf4\x8e\xbb\xae\xcc\x85\xcc\x8d"
    "\x1b[39m";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)placeholder_cmds,
                            strlen(placeholder_cmds));

  /*
   * The storage has a generation of its own. It changes when a program
   * sends, places or deletes an image, but not when images only move on
   * screen. That is why the frames below use the render state's
   * placements generation to know when to read the list again.
   */
  GhosttyKittyGraphics graphics = NULL;
  if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                           &graphics) != GHOSTTY_SUCCESS || !graphics) {
    fprintf(stderr, "Failed to get kitty graphics storage\n");
    return 1;
  }
  uint64_t storage_generation = 0;
  ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION,
                             &storage_generation);
  printf("\nStorage generation: %llu\n",
         (unsigned long long)storage_generation);

  /* Find what to draw from the render state, over three frames. */
  if (run_frames(terminal) != 0) return 1;

  /* Animate a second image by driving the animation tick. */
  printf("\nPlaying an animation:\n");
  if (run_animation(terminal) != 0) return 1;

  /* Clean up. */
  ghostty_terminal_free(terminal);

  /* Clear the sys callbacks. */
  ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, NULL);
  ghostty_sys_set(GHOSTTY_SYS_OPT_USERDATA, NULL);

  return 0;
}
//! [kitty-graphics-main]
