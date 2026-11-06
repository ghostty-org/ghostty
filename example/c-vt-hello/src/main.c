//! [hello]
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main(void) {
  GhosttyTerminal terminal;
  ghostty_terminal_new(NULL, &terminal, 80, 24);

  const char *text = "Hello, \x1b[1;32mworld\x1b[0m!\r\n";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

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
