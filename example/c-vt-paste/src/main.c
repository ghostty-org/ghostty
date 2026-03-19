#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [paste-safety]
void basic_example() {
  const char* safe_data = "hello world";
  const char* unsafe_data = "rm -rf /\n";

  if (ghostty_paste_is_safe(safe_data, strlen(safe_data))) {
    printf("Safe to paste\n");
  }

  if (!ghostty_paste_is_safe(unsafe_data, strlen(unsafe_data))) {
    printf("Unsafe! Contains newline\n");
  }
}
//! [paste-safety]

int main() {
  basic_example();

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
