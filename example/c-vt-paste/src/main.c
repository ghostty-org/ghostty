#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main() {
  // Test safe paste data
  const char *safe_data = "hello world";
  if (ghostty_paste_is_safe(safe_data, strlen(safe_data))) {
    printf("'%s' is safe to paste\n", safe_data);
  }

  // Test unsafe paste data with newline
  const char *unsafe_newline = "rm -rf /\n";
  if (!ghostty_paste_is_safe(unsafe_newline, strlen(unsafe_newline))) {
    printf("'%s' is UNSAFE - contains newline\n", unsafe_newline);
  }

  // Test unsafe paste data with bracketed paste end sequence
  const char *unsafe_escape = "evil\x1b[201~code";
  if (!ghostty_paste_is_safe(unsafe_escape, strlen(unsafe_escape))) {
    printf("Data with escape sequence is UNSAFE\n");
  }

  // Test empty data
  const char *empty_data = "";
  if (ghostty_paste_is_safe(empty_data, 0)) {
    printf("Empty data is safe\n");
  }

  return 0;
}
