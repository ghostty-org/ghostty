#include <simdutf.h>

extern "C" {

size_t ghostty_simd_count_utf8(const char* input, size_t length) {
  return simdutf::count_utf8(input, length);
}

}  // extern "C"
