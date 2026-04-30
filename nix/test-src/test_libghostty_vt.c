#include <ghostty/vt.h>
#include <stdio.h>
int main(void) {
    bool simd = false;
    GhosttyResult r = ghostty_build_info(GHOSTTY_BUILD_INFO_SIMD, &simd);
    if (r != GHOSTTY_SUCCESS) return 1;
    printf("SIMD: %s\n", simd ? "yes" : "no");
    return 0;
}
