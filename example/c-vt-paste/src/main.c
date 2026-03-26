#include <stdio.h>
#include <stdlib.h>
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
  const char* original = "hello\nworld";
  size_t len = strlen(original);

  // encodePaste modifies data in place, so make a mutable copy.
  uint8_t* data = malloc(len);
  memcpy(data, original, len);

  // First call with NULL buffer to query the required size.
  size_t written = 0;
  ghostty_clipboard_encode_paste(data, len, true, NULL, 0, &written);

  // Allocate and encode.
  char* buf = malloc(written);
  GhosttyResult result =
      ghostty_clipboard_encode_paste(data, len, true, buf, written, &written);
  if (result == GHOSTTY_SUCCESS) {
    printf("Encoded %zu bytes\n", written);
    fwrite(buf, 1, written, stdout);
    printf("\n");
  }

  free(buf);
  free(data);
}
//! [paste-encode]

int main() {
  safety_example();
  encode_example();

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
