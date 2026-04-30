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

//! [kitty-graphics-main]
int main() {
  /* Install the PNG decoder via the sys interface. */
  int decode_count = 0;
  ghostty_sys_set(GHOSTTY_SYS_OPT_USERDATA, &decode_count);
  ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, (const void*)decode_png);

  /* Create a terminal with Kitty graphics enabled. */
  GhosttyTerminal terminal = NULL;
  GhosttyTerminalOptions opts = {
    .cols = 80,
    .rows = 24,
    .max_scrollback = 0,
  };
  if (ghostty_terminal_new(NULL, &terminal, opts) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create terminal\n");
    return 1;
  }

  /* Set cell pixel dimensions so kitty graphics can compute grid sizes. */
  ghostty_terminal_resize(terminal, 80, 24, 8, 16);

  /* Set a storage limit to enable Kitty graphics. */
  uint64_t storage_limit = 64 * 1024 * 1024;  /* 64 MiB */
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                       &storage_limit);

  /* Install write_pty to see the protocol response. */
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       (const void*)on_write_pty);

  /*
   * Send a Kitty graphics command with an inline 1x1 PNG image.
   *
   * The escape sequence is:
   *   ESC _G a=T,f=100,q=1; <base64 PNG data> ESC \
   *
   * Where:
   *   a=T   — transmit and display
   *   f=100 — PNG format
   *   q=1   — request a response (q=0 would suppress it)
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

  /* Query the kitty graphics storage to verify the image was stored. */
  GhosttyKittyGraphics graphics = NULL;
  if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                           &graphics) != GHOSTTY_SUCCESS || !graphics) {
    fprintf(stderr, "Failed to get kitty graphics storage\n");
    return 1;
  }
  printf("\nKitty graphics storage is available.\n");

  /* Iterate placements to find the image ID. */
  GhosttyKittyGraphicsPlacementIterator iter = NULL;
  if (ghostty_kitty_graphics_placement_iterator_new(NULL, &iter) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create placement iterator\n");
    return 1;
  }
  if (ghostty_kitty_graphics_get(graphics,
          GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iter) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to get placement iterator\n");
    return 1;
  }

  int placement_count = 0;
  while (ghostty_kitty_graphics_placement_next(iter)) {
    placement_count++;
    uint32_t image_id = 0;
    uint32_t placement_id = 0;
    bool is_virtual = false;
    int32_t z = 0;

    ghostty_kitty_graphics_placement_get_multi(iter, 4,
        (GhosttyKittyGraphicsPlacementData[]){
            GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
            GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
            GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
            GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z,
        },
        (void*[]){ &image_id, &placement_id, &is_virtual, &z },
        NULL);

    printf("  placement #%d: image_id=%u placement_id=%u virtual=%s z=%d\n",
           placement_count, image_id, placement_id,
           is_virtual ? "true" : "false", z);

    /* Look up the image and print its properties. */
    GhosttyKittyGraphicsImage image =
        ghostty_kitty_graphics_image(graphics, image_id);
    if (!image) {
      fprintf(stderr, "Failed to look up image %u\n", image_id);
      return 1;
    }

    uint32_t width = 0, height = 0, number = 0;
    GhosttyKittyImageFormat format = 0;
    size_t data_len = 0;

    ghostty_kitty_graphics_image_get_multi(image, 5,
        (GhosttyKittyGraphicsImageData[]){
            GHOSTTY_KITTY_IMAGE_DATA_NUMBER,
            GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
            GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
            GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
            GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN,
        },
        (void*[]){ &number, &width, &height, &format, &data_len },
        NULL);

    printf("    image: number=%u size=%ux%u format=%d data_len=%zu\n",
           number, width, height, format, data_len);

    /* Compute the rendered pixel size and grid size. */
    uint32_t px_w = 0, px_h = 0, cols = 0, rows = 0;
    if (ghostty_kitty_graphics_placement_pixel_size(iter, image, terminal,
            &px_w, &px_h) == GHOSTTY_SUCCESS) {
      printf("    rendered pixel size: %ux%u\n", px_w, px_h);
    }
    if (ghostty_kitty_graphics_placement_grid_size(iter, image, terminal,
            &cols, &rows) == GHOSTTY_SUCCESS) {
      printf("    grid size: %u cols x %u rows\n", cols, rows);
    }
  }
  printf("Total placements: %d\n", placement_count);
  ghostty_kitty_graphics_placement_iterator_free(iter);

  /* Clean up. */
  ghostty_terminal_free(terminal);

  /* Clear the sys callbacks. */
  ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, NULL);
  ghostty_sys_set(GHOSTTY_SYS_OPT_USERDATA, NULL);

  return 0;
}
//! [kitty-graphics-main]
