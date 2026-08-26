#include <stdio.h>
#include <ghostty/vt.h>

//! [focus-encode]
int main() {
  char buf[8];
  size_t written = 0;

  GhosttyResult result = ghostty_focus_encode(
      GHOSTTY_FOCUS_GAINED, buf, sizeof(buf), &written);

  if (result == GHOSTTY_SUCCESS) {
    printf("Encoded %zu bytes: ", written);
    fwrite(buf, 1, written, stdout);
    printf("\n");
  }

  return 0;
}
//! [focus-encode]
