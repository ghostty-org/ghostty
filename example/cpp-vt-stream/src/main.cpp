#include <cassert>
#include <cstdio>
#include <cstring>
#include <ghostty/vt.h>

int main() {
  // Create a terminal
  GhosttyTerminal terminal;
  GhosttyResult result = ghostty_terminal_new(nullptr, &terminal, 80, 24);
  assert(result == GHOSTTY_SUCCESS);

  // Feed VT data into the terminal
  const char *text = "Hello from C++!\r\n";
  ghostty_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  text = "\x1b[1;32mGreen Text\x1b[0m\r\n";
  ghostty_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  text = "\x1b[1;1HTop-left corner\r\n";
  ghostty_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  // Get the final terminal state as a plain string
  GhosttyFormatter formatter;
  result = ghostty_formatter_terminal_new(nullptr, &formatter, terminal);
  assert(result == GHOSTTY_SUCCESS);

  GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
  assert(result == GHOSTTY_SUCCESS);

  bool trim = true;
  result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
  assert(result == GHOSTTY_SUCCESS);

  uint8_t *buf = nullptr;
  size_t len = 0;
  result = ghostty_formatter_format_alloc(formatter, nullptr, &buf, &len);
  assert(result == GHOSTTY_SUCCESS);

  std::fwrite(buf, 1, len, stdout);
  std::printf("\n");

  ghostty_free(nullptr, buf, len);
  ghostty_formatter_free(formatter);
  ghostty_terminal_free(terminal);
  return 0;
}
