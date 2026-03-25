#include <stdio.h>
#include <ghostty/vt.h>

//! [build-info-query]
void query_build_info() {
  bool simd = false;
  bool kitty_graphics = false;
  bool tmux_control_mode = false;

  ghostty_build_info(GHOSTTY_BUILD_INFO_SIMD, &simd);
  ghostty_build_info(GHOSTTY_BUILD_INFO_KITTY_GRAPHICS, &kitty_graphics);
  ghostty_build_info(GHOSTTY_BUILD_INFO_TMUX_CONTROL_MODE, &tmux_control_mode);

  printf("SIMD: %s\n", simd ? "enabled" : "disabled");
  printf("Kitty graphics: %s\n", kitty_graphics ? "enabled" : "disabled");
  printf("Tmux control mode: %s\n", tmux_control_mode ? "enabled" : "disabled");
}
//! [build-info-query]

int main() {
  query_build_info();
  return 0;
}
