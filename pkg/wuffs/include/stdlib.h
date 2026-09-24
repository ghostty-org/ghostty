// Minimal stdlib.h so that wuffs can be translated and compiled without
// requiring libc headers. See string.h in this directory for details.
#ifndef GHOSTTY_WUFFS_STDLIB_H
#define GHOSTTY_WUFFS_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);

#endif
