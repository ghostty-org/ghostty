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

  // Write some VT-encoded content into the terminal
  const char *commands[] = {
    "Hello from a \033[1mCMake\033[0m-built program!\r\n",
    "Line 2: \033[4munderlined\033[0m text\r\n",
    "Line 3: \033[31mred\033[0m \033[32mgreen\033[0m \033[34mblue\033[0m\r\n",
  };
  for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
    ghostty_terminal_vt_write(terminal, (const uint8_t *)commands[i],
                              strlen(commands[i]));
  }

  // Format the terminal contents as plain text
  GhosttyFormatterTerminalOptions fmt_opts =
      GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
  fmt_opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  fmt_opts.trim = true;

  GhosttyFormatter formatter;
  result = ghostty_formatter_terminal_new(NULL, &formatter, terminal, fmt_opts);
  assert(result == GHOSTTY_SUCCESS);

  uint8_t *buf = NULL;
  size_t len = 0;
  result = ghostty_formatter_format_alloc(formatter, NULL, &buf, &len);
  assert(result == GHOSTTY_SUCCESS);

  printf("Plain text (%zu bytes):\n", len);
  fwrite(buf, 1, len, stdout);
  printf("\n");

  free(buf);
  ghostty_formatter_free(formatter);
  ghostty_terminal_free(terminal);
  return 0;
}
