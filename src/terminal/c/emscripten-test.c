/* Run with .github/scripts/check-emscripten-libghostty-vt.sh. */
#include <assert.h>
#include <ghostty/vt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FUNCTIONS(X)                \
  X(ghostty_terminal_new)           \
  X(ghostty_terminal_free)          \
  X(ghostty_terminal_resize)        \
  X(ghostty_terminal_vt_write)      \
  X(ghostty_formatter_terminal_new) \
  X(ghostty_formatter_format_alloc) \
  X(ghostty_formatter_free)         \
  X(ghostty_free)

#ifdef TEST_DYNAMIC
#include <dlfcn.h>
#define DECLARE(name) static __typeof__(&name) api_##name;
FUNCTIONS(DECLARE)
#define API(name) api_##name
#else
#define API(name) name
#endif

static size_t live_bytes;
static size_t page_allocations;

static void* dirty_alloc(void* ctx,
                         size_t len,
                         uint8_t alignment,
                         uintptr_t ret_addr) {
  (void)ctx;
  (void)ret_addr;
  size_t align = (size_t)1 << alignment;
  if (align < sizeof(void*))
    align = sizeof(void*);
  void* memory = aligned_alloc(align, (len + align - 1) & ~(align - 1));
  if (memory) {
    memset(memory, 0xa5, len);
    live_bytes += len;
    if (align >= 4096)
      page_allocations++;
  }
  return memory;
}

static void dirty_free(void* ctx,
                       void* memory,
                       size_t len,
                       uint8_t alignment,
                       uintptr_t ret_addr) {
  (void)ctx;
  (void)alignment;
  (void)ret_addr;
  assert(live_bytes >= len);
  live_bytes -= len;
  memset(memory, 0x5a, len);
  free(memory);
}

static const GhosttyAllocatorVtable vtable = {
    .alloc = dirty_alloc,
    .free = dirty_free,
};

static void exercise(const GhosttyAllocator* allocator) {
  /* Keep host allocations live while Ghostty grows and reuses its heap. */
  unsigned char* host = malloc(65536);
  assert(host);
  memset(host, 0x3c, 65536);
  for (int pass = 0; pass < 3; pass++) {
    GhosttyTerminal terminal = NULL;
    assert(API(ghostty_terminal_new)(allocator, &terminal, 80, 24) ==
           GHOSTTY_SUCCESS);
    const char* line = "\033[31mhello wasm\033[0m\r\n";
    for (int row = 0; row < 2000; row++)
      API(ghostty_terminal_vt_write)(terminal, (const uint8_t*)line,
                                     strlen(line));
    /* Exercise reflow in both directions. */
    assert(API(ghostty_terminal_resize)(terminal, 5000, 24, 8, 16) ==
           GHOSTTY_SUCCESS);
    assert(API(ghostty_terminal_resize)(terminal, 80, 24, 8, 16) ==
           GHOSTTY_SUCCESS);
    API(ghostty_terminal_vt_write)(terminal, (const uint8_t*)line,
                                   strlen(line));
    GhosttyFormatter formatter = NULL;
    assert(API(ghostty_formatter_terminal_new)(allocator, &formatter,
                                               terminal) == GHOSTTY_SUCCESS);
    uint8_t* buffer = NULL;
    size_t length = 0;
    assert(API(ghostty_formatter_format_alloc)(formatter, allocator, &buffer,
                                               &length) == GHOSTTY_SUCCESS);
    char* copy = malloc(length + 1);
    assert(copy);
    memcpy(copy, buffer, length);
    copy[length] = '\0';
    assert(strstr(copy, "hello wasm"));
    free(copy);
    API(ghostty_free)(allocator, buffer, length);
    API(ghostty_formatter_free)(formatter);
    API(ghostty_terminal_free)(terminal);
    assert(live_bytes == 0);
    for (size_t i = 0; i < 65536; i++)
      assert(host[i] == 0x3c);
  }
  free(host);
}

int main(void) {
#ifdef TEST_DYNAMIC
  void* handle = dlopen("/libghostty-vt.so", RTLD_NOW | RTLD_LOCAL);
  assert(handle);
#define LOAD(name)                                      \
  api_##name = (__typeof__(&name))dlsym(handle, #name); \
  assert(api_##name);
  FUNCTIONS(LOAD)
#endif
  exercise(NULL);
  GhosttyAllocator allocator = {.vtable = &vtable};
  exercise(&allocator);
  assert(page_allocations > 0);
  /* A single row wider than the standard page capacity cannot use the
   * normal page pool. Cover initial allocation and reflow of that page. */
  GhosttyTerminal wide = NULL;
  assert(API(ghostty_terminal_new)(&allocator, &wide, UINT16_MAX, 1) ==
         GHOSTTY_SUCCESS);
  assert(API(ghostty_terminal_resize)(wide, 80, 1, 8, 16) == GHOSTTY_SUCCESS);
  API(ghostty_terminal_free)(wide);
  assert(live_bytes == 0);
#ifdef TEST_DYNAMIC
  assert(dlclose(handle) == 0);
#endif
  puts("Emscripten allocation tests passed");
  return 0;
}
