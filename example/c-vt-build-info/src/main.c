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

  GhosttyString version_string = {0};
  size_t version_major = 0;
  size_t version_minor = 0;
  size_t version_patch = 0;
  GhosttyString version_pre = {0};
  GhosttyString version_build = {0};

  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, &version_string);
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_MAJOR, &version_major);
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_MINOR, &version_minor);
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_PATCH, &version_patch);
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_PRE, &version_pre);
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_BUILD, &version_build);

  printf("Version: %.*s\n", (int)version_string.len, version_string.ptr);
  printf("Version major: %zu\n", version_major);
  printf("Version minor: %zu\n", version_minor);
  printf("Version patch: %zu\n", version_patch);
  if (version_pre.len > 0) {
    printf("Version pre  : %.*s\n", (int)version_pre.len, version_pre.ptr);
  } else {
    printf("Version pre  : (none)\n");
  }
  if (version_build.len > 0) {
    printf("Version build: %.*s\n", (int)version_build.len, version_build.ptr);
  } else {
    printf("Version build: (none)\n");
  }
}
//! [build-info-query]

//! [version-check]
// Stop the build if the headers are older than this program needs.
#if !GHOSTTY_VT_VERSION_AT_LEAST(1, 0, 0)
#error "libghostty-vt 1.0.0 or newer is required"
#endif
//! [version-check]

//! [version-library]
void print_library_version() {
  // The full version, which is the easiest form to log or display. A
  // development build has a suffix, such as "1.1.0-dev+abc1234".
  printf("Library version: %s\n", ghostty_version());

  // The same version as numbers, which is the easiest form to compare.
  size_t major = 0;
  size_t minor = 0;
  size_t patch = 0;
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_MAJOR, &major);
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_MINOR, &minor);
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_PATCH, &patch);
  printf("Library version numbers: %zu.%zu.%zu\n", major, minor, patch);
}
//! [version-library]

//! [version-compatible]
// Returns true if the library loaded at runtime can be used with the
// headers this program was compiled against.
bool library_is_compatible() {
  size_t major = 0;
  size_t minor = 0;
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_MAJOR, &major);
  ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_MINOR, &minor);

  // The major versions must match. The library may be newer
  // than the headers but not older, because an older library is missing
  // the functions that newer headers declare.
  return major == GHOSTTY_VT_VERSION_MAJOR &&
         minor >= GHOSTTY_VT_VERSION_MINOR;
}
//! [version-compatible]

int main() {
  query_build_info();

  printf("Header version: %s\n", GHOSTTY_VT_VERSION);
  print_library_version();
  if (!library_is_compatible()) {
    fprintf(stderr, "This program needs libghostty-vt %d.%d.\n",
            GHOSTTY_VT_VERSION_MAJOR, GHOSTTY_VT_VERSION_MINOR);
    return 1;
  }

  return 0;
}
