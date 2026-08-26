#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ghostty/vt.h>

typedef struct {
  FILE *file;
  size_t written;
} OutputWriter;

static bool write_output(void *userdata, const uint8_t *data, size_t len) {
  OutputWriter *output = userdata;
  size_t offset = 0;
  while (offset < len) {
    size_t written = fwrite(data + offset, 1, len - offset, output->file);
    output->written += written;
    offset += written;
    if (written == 0) return false;
  }

  return true;
}

int main() {
  // Create a terminal with a small grid
  GhosttyTerminal terminal;
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, 80, 24);
  assert(result == GHOSTTY_SUCCESS);

  // Write VT-encoded content into the terminal to exercise various
  // cursor movement and styling sequences.
  const char *commands[] = {
    "Line 1: Hello World!\r\n",           // Simple text on row 1
    ("Line 2: \033[1mBold\033[0m and "     // Bold text on row 2
     "\033[4mUnderline\033[0m\r\n"),
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

  // Stream the formatted output directly to stdout. The writer retains the
  // exact byte count and reports destination errors through its return value.
  OutputWriter output = {.file = stdout};
  GhosttyWriter writer = {.write = write_output, .userdata = &output};
  printf("Formatted output:\n");
  result = ghostty_formatter_format(formatter, writer);
  assert(result == GHOSTTY_SUCCESS);
  printf("\n(%zu bytes)\n", output.written);

  // Clean up
  ghostty_formatter_free(formatter);
  ghostty_terminal_free(terminal);
  return 0;
}
