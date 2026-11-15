//! [hello]
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main(void) {
  // Create an 80x24 terminal. NULL selects the default allocator.
  GhosttyTerminal terminal;
  ghostty_terminal_new(NULL, &terminal, 80, 24);

  // Write the bytes a program would send. They can come from anywhere: a pty,
  // a network connection, a recording. The escape sequences make "world" bold
  // and green.
  const char *text = "Hello, \x1b[1;32mworld\x1b[0m!\r\n";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Read the screen back. A new formatter emits plain text, so the styles
  // don't appear in the output, but you can set options to enable that.
  GhosttyFormatter formatter;
  ghostty_formatter_terminal_new(NULL, &formatter, terminal);

  uint8_t *buf = NULL;
  size_t len = 0;
  ghostty_formatter_format_alloc(formatter, NULL, &buf, &len);
  fwrite(buf, 1, len, stdout);
  putchar('\n');

  ghostty_free(NULL, buf, len);
  ghostty_formatter_free(formatter);
  ghostty_terminal_free(terminal);
  return 0;
}
//! [hello]
