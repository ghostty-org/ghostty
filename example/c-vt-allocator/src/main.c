#include <stdalign.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <ghostty/vt.h>

/* The allocator's state. This example only counts, so it can check at
 * the end that the terminal freed everything it allocated. */
typedef struct {
  size_t allocs;
  size_t live_bytes;
} Stats;

//! [allocator-vtable]
/* `alignment` is an exponent. The address must be a multiple of
 * 1 << alignment bytes. */
static size_t align_bytes(uint8_t alignment) {
  return (size_t)1 << alignment;
}

/* malloc already returns memory aligned for any built-in C type. Only
 * larger alignments need extra work. */
static int needs_padding(uint8_t alignment) {
  return align_bytes(alignment) > alignof(max_align_t);
}

static void* my_alloc(void* ctx, size_t len, uint8_t alignment,
                      uintptr_t ret_addr) {
  (void)ret_addr;
  Stats* stats = ctx;

  void* result;
  if (!needs_padding(alignment)) {
    result = malloc(len);
  } else {
    /* Allocate extra room, round up to the alignment, and store the
     * pointer malloc returned just before the block so my_free can find
     * it again. */
    size_t align = align_bytes(alignment);
    void* raw = malloc(len + align + sizeof(void*));
    if (raw == NULL) return NULL;
    uintptr_t start = (uintptr_t)raw + sizeof(void*);
    uintptr_t aligned = (start + align - 1) & ~(uintptr_t)(align - 1);
    ((void**)aligned)[-1] = raw;
    result = (void*)aligned;
  }

  if (result != NULL) {
    stats->allocs++;
    stats->live_bytes += len;
  }
  return result;
}

static void my_free(void* ctx, void* memory, size_t memory_len,
                    uint8_t alignment, uintptr_t ret_addr) {
  (void)ret_addr;
  Stats* stats = ctx;
  stats->live_bytes -= memory_len;

  /* The library passes the same alignment it allocated with, so this
   * takes the same branch my_alloc did. */
  if (!needs_padding(alignment)) {
    free(memory);
  } else {
    free(((void**)memory)[-1]);
  }
}

/* Only alloc and free are set. The designated initializer sets every
 * other field to NULL. A NULL resize and remap tell the library to grow
 * memory by allocating, copying, and freeing, and the reserved slots
 * must be NULL. */
static const GhosttyAllocatorVtable my_vtable = {
    .alloc = my_alloc,
    .free = my_free,
};
//! [allocator-vtable]

int main(void) {
  //! [allocator-use]
  Stats stats = {0};
  GhosttyAllocator allocator = {
      .ctx = &stats,
      .vtable = &my_vtable,
  };

  /* The terminal keeps a pointer to the allocator, so `allocator` must
   * stay alive until ghostty_terminal_free(). */
  GhosttyTerminal terminal;
  if (ghostty_terminal_new(&allocator, &terminal, 80, 24) !=
      GHOSTTY_SUCCESS) {
    fprintf(stderr, "ghostty_terminal_new failed\n");
    return 1;
  }
  //! [allocator-use]

  /* Write enough styled output to fill the scrollback, so the terminal
   * has to grow its allocations. */
  char line[64];
  for (int i = 0; i < 20000; i++) {
    int n = snprintf(line, sizeof(line),
                     "\x1b[3%dmline %d with some text\x1b[0m\r\n", i % 8, i);
    ghostty_terminal_vt_write(terminal, (const uint8_t*)line, (size_t)n);
  }

  printf("Allocations: %zu\n", stats.allocs);
  printf("Live bytes before free: %zu\n", stats.live_bytes);

  ghostty_terminal_free(terminal);
  printf("Live bytes after free: %zu\n", stats.live_bytes);

  return stats.live_bytes == 0 ? 0 : 1;
}
