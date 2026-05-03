#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [colors-set-defaults]
/// Set up a dark color theme with custom palette entries.
void set_color_theme(GhosttyTerminal terminal) {
  // Set default foreground (light gray) and background (dark)
  GhosttyColorRgb fg = { .r = 0xDD, .g = 0xDD, .b = 0xDD };
  GhosttyColorRgb bg = { .r = 0x1E, .g = 0x1E, .b = 0x2E };
  GhosttyColorRgb cursor = { .r = 0xF5, .g = 0xE0, .b = 0xDC };

  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor);

  // Set a custom palette — start from the built-in default and override
  // the first 8 entries with a custom dark theme.
  GhosttyColorRgb palette[256];
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, palette);

  palette[GHOSTTY_COLOR_NAMED_BLACK]   = (GhosttyColorRgb){ 0x45, 0x47, 0x5A };
  palette[GHOSTTY_COLOR_NAMED_RED]     = (GhosttyColorRgb){ 0xF3, 0x8B, 0xA8 };
  palette[GHOSTTY_COLOR_NAMED_GREEN]   = (GhosttyColorRgb){ 0xA6, 0xE3, 0xA1 };
  palette[GHOSTTY_COLOR_NAMED_YELLOW]  = (GhosttyColorRgb){ 0xF9, 0xE2, 0xAF };
  palette[GHOSTTY_COLOR_NAMED_BLUE]    = (GhosttyColorRgb){ 0x89, 0xB4, 0xFA };
  palette[GHOSTTY_COLOR_NAMED_MAGENTA] = (GhosttyColorRgb){ 0xF5, 0xC2, 0xE7 };
  palette[GHOSTTY_COLOR_NAMED_CYAN]    = (GhosttyColorRgb){ 0x94, 0xE2, 0xD5 };
  palette[GHOSTTY_COLOR_NAMED_WHITE]   = (GhosttyColorRgb){ 0xBA, 0xC2, 0xDE };

  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette);
}
//! [colors-set-defaults]

//! [colors-read]
/// Print the effective and default values for a color, showing how
/// OSC overrides layer on top of defaults.
void print_color(GhosttyTerminal terminal,
                 const char* name,
                 GhosttyTerminalData effective_data,
                 GhosttyTerminalData default_data) {
  GhosttyColorRgb color;

  GhosttyResult res = ghostty_terminal_get(terminal, effective_data, &color);
  if (res == GHOSTTY_SUCCESS) {
    printf("  %-12s effective: #%02X%02X%02X", name, color.r, color.g, color.b);
  } else {
    printf("  %-12s effective: (not set)", name);
  }

  res = ghostty_terminal_get(terminal, default_data, &color);
  if (res == GHOSTTY_SUCCESS) {
    printf("  default: #%02X%02X%02X\n", color.r, color.g, color.b);
  } else {
    printf("  default: (not set)\n");
  }
}

void print_all_colors(GhosttyTerminal terminal, const char* label) {
  printf("%s:\n", label);
  print_color(terminal, "foreground",
      GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
      GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT);
  print_color(terminal, "background",
      GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
      GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT);
  print_color(terminal, "cursor",
      GHOSTTY_TERMINAL_DATA_COLOR_CURSOR,
      GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT);

  // Show palette index 0 (black) as an example
  GhosttyColorRgb palette[256];
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, palette);
  printf("  %-12s effective: #%02X%02X%02X", "palette[0]",
      palette[0].r, palette[0].g, palette[0].b);

  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
      palette);
  printf("  default: #%02X%02X%02X\n", palette[0].r, palette[0].g, palette[0].b);
}
//! [colors-read]

//! [colors-main]
int main() {
  // Create a terminal
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

  // Before setting any colors, everything is unset
  print_all_colors(terminal, "Before setting defaults");

  // Set our color theme defaults
  set_color_theme(terminal);
  print_all_colors(terminal, "\nAfter setting defaults");

  // Simulate an OSC override (e.g. a program running inside the
  // terminal changes the foreground via OSC 10)
  const char* osc_fg = "\x1B]10;rgb:FF/00/00\x1B\\";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)osc_fg,
                            strlen(osc_fg));
  print_all_colors(terminal, "\nAfter OSC foreground override");

  // Clear the foreground default — the OSC override is still active
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, NULL);
  print_all_colors(terminal, "\nAfter clearing foreground default");

  ghostty_terminal_free(terminal);
  return 0;
}
//! [colors-main]
