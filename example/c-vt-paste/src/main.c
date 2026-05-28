#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [paste-safety]
void safety_example() {
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

//! [paste-encode]
void encode_example() {
  // The input buffer is modified in place (unsafe bytes are stripped).
  char data[] = "hello\nworld";
  char buf[64];
  size_t written = 0;

  GhosttyResult result = ghostty_paste_encode(
      data, strlen(data), true, buf, sizeof(buf), &written);

  if (result == GHOSTTY_SUCCESS) {
    printf("Encoded %zu bytes: ", written);
    fwrite(buf, 1, written, stdout);
    printf("\n");
  }
}
//! [paste-encode]

int main() {
  safety_example();

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

  encode_example();

  return 0;
}
