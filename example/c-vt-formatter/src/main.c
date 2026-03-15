#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ghostty/vt.h>

int main() {
  // Create a terminal with a small grid
  GhosttyTerminal terminal;
  GhosttyTerminalOptions opts = {
    .cols = 80,
    .rows = 24,
    .max_scrollback = 0,
  };
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, opts);
  assert(result == GHOSTTY_SUCCESS);

  // Write VT-encoded content into the terminal to exercise various
  // cursor movement and styling sequences.
  const char *commands[] = {
    "Line 1: Hello World!\r\n",           // Simple text on row 1
    "Line 2: \033[1mBold\033[0m and "     // Bold text on row 2
      "\033[4mUnderline\033[0m\r\n",
    "Line 3: placeholder\r\n",            // Will be overwritten below
    "\033[3;1H",                          // CUP: move cursor back to row 3, col 1
    "\033[2K",                            // EL:  erase the entire line
    "Line 3: Overwritten!\r\n",           // Rewrite row 3 with new content
    "\033[5;10H",                         // CUP: jump to row 5, col 10
    "Placed at (5,10)",                   // Write at that position
    "\033[1;72H",                         // CUP: jump to row 1, col 72
    "RIGHT->",                            // Near the right edge of row 1
  };
  for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
    ghostty_terminal_vt_write(terminal, (const uint8_t *)commands[i],
                              strlen(commands[i]));
  }

  // Create a plain-text formatter for the terminal
  GhosttyFormatterTerminalOptions fmt_opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
  fmt_opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  fmt_opts.trim = true;

  GhosttyFormatter formatter;
  result = ghostty_formatter_terminal_new(NULL, &formatter, terminal, fmt_opts);
  assert(result == GHOSTTY_SUCCESS);

  // Format into an allocated buffer
  uint8_t *buf = NULL;
  size_t len = 0;
  result = ghostty_formatter_format_alloc(formatter, NULL, &buf, &len);
  assert(result == GHOSTTY_SUCCESS);

  // Print the formatted output
  printf("Formatted output (%zu bytes):\n", len);
  fwrite(buf, 1, len, stdout);
  printf("\n");

  // Clean up
  free(buf);
  ghostty_formatter_free(formatter);
  ghostty_terminal_free(terminal);
  return 0;
}
