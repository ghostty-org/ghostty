#include <ghostty/vt.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

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

  // Create options for paste encoding
  GhosttyPasteOptions options;
  if (ghostty_paste_options_new(NULL, &options) != GHOSTTY_SUCCESS) {
    printf("Failed to create paste options\n");
    return 1;
  }

  // Enable bracketed paste mode
  ghostty_paste_options_set_bracketed(options, true);

  char *simple_paste = "pasted content";
  char *encoded;
  if (ghostty_paste_encode(NULL, simple_paste, strlen(simple_paste), options,
                           &encoded) != GHOSTTY_SUCCESS) {
    printf("Failed to encode paste data\n");
    return 1;
  }

  printf("Encoded paste data: ");
  for (size_t i = 0; i < strlen(encoded); i++) {
    if (encoded[i] == 0x1b) {
      printf("\\x1b");
    } else {
      printf("%c", encoded[i]);
    }
  }
  printf("\n");

  // Disable bracketed paste mode, so that \n will be replaced by \r
  ghostty_paste_options_set_bracketed(options, false);

  char *multiline_paste = "line1\nline2\n";
  char *encoded_multi;

  if (ghostty_paste_encode(NULL, multiline_paste, strlen(multiline_paste),
                           options, &encoded_multi) != GHOSTTY_SUCCESS) {
    printf("Failed to encode multiline paste data\n");
    return 1;
  }

  printf("Encoded multiline paste data without bracketed: ");
  for (size_t i = 0; i < strlen(encoded_multi); i++) {
    if (encoded_multi[i] == 0x1b) {
      printf("\\x1b");
    } else if (encoded_multi[i] == '\r') {
      printf("\\r");
    } else {
      printf("%c", encoded_multi[i]);
    }
  }
  printf("\n");

  // free resources
  ghostty_paste_encode_free(NULL, encoded, strlen(encoded));
  ghostty_paste_encode_free(NULL, encoded_multi, strlen(encoded_multi));
  ghostty_paste_options_free(NULL, options);

  return 0;
}
