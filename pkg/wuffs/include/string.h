// Minimal string.h so that wuffs can be translated and compiled without
// requiring libc headers (e.g. for wasm32-freestanding targets, or to
// avoid needing an Apple SDK for translate-c on macOS).
//
// Wuffs only calls the mem* family, whose symbols are provided by Zig's
// compiler-rt on targets without libc and by libc everywhere else. The
// declarations here match the standard C ABI, so this header is safe to
// use on every target, including ones that do link libc.
#ifndef GHOSTTY_WUFFS_STRING_H
#define GHOSTTY_WUFFS_STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *b, int c, size_t n);
int memcmp(const void *s1, const void *s2, size_t n);
size_t strlen(const char *s);
int strcmp(const char *s1, const char *s2);
int strncmp(const char *s1, const char *s2, size_t n);

#endif
