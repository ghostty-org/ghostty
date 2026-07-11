#include <stdio.h>
#include <ghostty/vt.h>

//! [color-scheme-report-encode]
int main() {
  char buf[16];
  size_t written = 0;

  GhosttyResult result = ghostty_color_scheme_report_encode(
      GHOSTTY_COLOR_SCHEME_DARK, buf, sizeof(buf), &written);

  if (result == GHOSTTY_SUCCESS) {
    printf("Encoded %zu bytes: ", written);
    fwrite(buf, 1, written, stdout);
    printf("\n");
  }

  return 0;
}
//! [color-scheme-report-encode]
