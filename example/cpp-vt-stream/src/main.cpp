#include <cassert>
#include <cstdio>
#include <cstring>
#include <ghostty/vt.h>

int main() {
  // Create a terminal
  GhosttyTerminal terminal;
  GhosttyTerminalOptions opts = {
    .cols = 80,
    .rows = 24,
    .max_scrollback = 0,
  };
  GhosttyResult result = ghostty_terminal_new(nullptr, &terminal, opts);
  assert(result == GHOSTTY_SUCCESS);

  // Feed VT data into the terminal
  const char *text = "Hello from C++!\r\n";
  ghostty_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  text = "\x1b[1;32mGreen Text\x1b[0m\r\n";
  ghostty_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  text = "\x1b[1;1HTop-left corner\r\n";
  ghostty_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  // Get the final terminal state as a plain string
  GhosttyFormatterTerminalOptions fmt_opts =
      GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
  fmt_opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  fmt_opts.trim = true;

  GhosttyFormatter formatter;
  result = ghostty_formatter_terminal_new(nullptr, &formatter, terminal, fmt_opts);
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
