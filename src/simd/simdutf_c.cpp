#include "simdutf.cpp"

// This is just the C API we need from Zig. This is manually maintained
// because the surface area is so small.
extern "C" {

size_t simdutf_convert_utf8_to_utf32(const char *src, size_t len, char32_t *dst) {
    return simdutf::convert_utf8_to_utf32(src, len, dst);
}

}
